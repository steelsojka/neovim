local query = require'vim.treesitter.query'
local language = require'vim.treesitter.language'

local LanguageTree = {}
LanguageTree.__index = LanguageTree

function LanguageTree.new(source, lang, opts)
  opts = opts or {}
  language.require_language(lang)

  local self = setmetatable({source=source, lang=lang, valid=false}, LanguageTree)

  self.root = opts.root or self
  self.parent = opts.parent
  self.children = {}
  self.tree = nil
  self.injection_query = query.get_query(lang, "injections")
  self._valid = false

  -- If a root language then setup the parser.
  if not self.parent then
    self._parser = vim._create_ts_parser(lang)
    self.callbacks = {
      changedtree = {},
      bytes = {},
      child_added = {},
      child_removed = {}
    }
  end

  return self
end

-- Invalidates this parser and all it's children
function LanguageTree:invalidate()
  self._valid = false

  for _, child in ipairs(self.children) do
    child:invalidate()
  end
end

function LanguageTree:is_valid()
  return self._valid
end

function LanguageTree:parse()
  local changes = self:_parse({})

  self._do_callback('changedtree', changes)

  return changes
end

function LanguageTree:for_each_child(fn, include_self)
  if include_self then
    fn(self, self.lang)
  end

  for lang, child in pairs(self.children) do
    fn(child, lang)

    child:for_each_child(fn)
  end
end

function LanguageTree:add_child(lang)
  if self.children[lang] then
    self.remove_child(lang)
  end

  self.children[lang] = LanguageTree.new(self.source, lang, {
    parent = self,
    root = self.root
  })

  self:invalidate()
  self._do_callback('child_added', self.children[lang])

  return self.children[lang]
end

function LanguageTree:remove_child(lang)
  local child = self.children[lang]

  if child then
    self.children[lang] = nil
    child:destroy()
    self:invalidate()
    self._do_callback('child_removed', child)
  end
end

function LanguageTree:destroy()
  -- Cleanup here
  for _, child in ipairs(self.children) do
    child:destroy()
  end
end

function LanguageTree:set_included_ranges(ranges)
  self.included_ranges = #ranges == 0 and nil or ranges
  self:invalidate()
end

function LanguageTree:_parse(changes)
  if self._valid then
    return changes
  end

  local parser = self.root._parser
  local included_ranges = self.included_ranges or {}

  parser:set_language(self.lang)
  parser:set_included_ranges(included_ranges)

  local tree, subchanges = parser:parse(self.source)

  table.insert(changes, subchanges)

  local injections_by_lang = self._get_injections()
  local seen_langs = {}

  for lang, injections in pairs(injections_by_lang) do
    local child = self.children[lang]

    if not child then
      child = self:add_child(lang)
    end

    child:set_included_ranges(injections)
    child:_parse(changes)
    seen_langs[lang] = true
  end

  for lang, _ in pairs(self.children) do
    if not seen_langs[lang] then
      self:remove_child(lang)
    end
  end

  self._valid = true

  return changes
end

function LanguageTree:_get_injections()
  local injections = {}

  for pattern, match in self.injection_query:iter_matches(region.tree, self.source, region.start_row, region.end_row + 1) do
    if pattern ~= nil then
      local lang = nil
      local injection_node = nil

      for id, node in pairs(match) do
        local name = query.captures[id]

        -- Lang should override any other language tag
        if name == "lang" then
          lang = query.get_node_text(node, self.source)
        else
          if lang == nil then
            lang = name
          end

          injection_node = node
        end
      end

      if not injections[lang] then
        injections[lang] = {}
      end

      table.insert(injections[lang], injection_node)
    end
  end

  return injections
end

function LanguageTree:_do_callback(cb, ...)
  for _, cb in ipairs(self.root.callbacks[cb]) do
    cb(...)
  end
end

function LanguageTree:_on_bytes(bufnr, changed_tick,
                          start_row, start_col, start_byte,
                          old_row, old_col, old_byte,
                          new_row, new_col, new_byte)
  self:invalidate()

  local changes = self:_parse({})

  self:_do_callback('bytes', bufnr, changed_tick,
      start_row, start_col, start_byte,
      old_row, old_col, old_byte,
      new_row, new_col, new_byte)
  self:_do_callback('changedtree', changes)
end

--- Registers callbacks for the parser
-- @param cbs An `nvim_buf_attach`-like table argument with the following keys :
--  `on_bytes` : see `nvim_buf_attach`, but this will be called _after_ the parsers callback.
--  `on_changedtree` : a callback that will be called everytime the tree has syntactical changes.
--      it will only be passed one argument, that is a table of the ranges (as node ranges) that
--      changed.
function LanguageTree:register_cbs(cbs)
  if not cbs then return end

  if cbs.on_changedtree then
    table.insert(self.root.callbacks.changedtree, cbs.on_changedtree)
  end

  if cbs.on_bytes then
    table.insert(self.root.callbacks.bytes, cbs.on_bytes)
  end

  if cbs.on_child_added then
    table.insert(self.root.callbacks.child_added, cbs.on_child_added)
  end

  if cbs.on_child_removed then
    table.insert(self.root.callbacks.child_removed, cbs.on_child_removed)
  end
end

return LanguageTree
