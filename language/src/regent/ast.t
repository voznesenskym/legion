-- Copyright 2016 Stanford University, NVIDIA Corporation
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

-- Legion AST

local data = require("regent/data")

local ast_factory = {}

local function make_factory(name)
  return setmetatable(
    {
      parent = false,
      name = name,
      expected_fields = false,
      expected_field_set = false,
      print_collapsed = false,
      print_hidden = false,
    },
    ast_factory)
end

local ast = make_factory("ast")
ast.make_factory = make_factory

-- Nodes

local ast_node = {}

function ast_node:__index(field)
  local value = ast_node[field]
  if value ~= nil then
    return value
  end
  local node_type = tostring(rawget(self, "node_type")) or "(unknown)"
  error(node_type .. " has no field '" .. field .. "' (in lookup)", 2)
end

function ast_node:__newindex(field, value)
  local node_type = tostring(rawget(self, "node_type")) or "(unknown)"
  error(node_type .. " has no field '" .. field .. "' (in assignment)", 2)
end

ast_node.hash = false -- Don't blow up inside a data.newmap()

function ast.is_node(node)
  return type(node) == "table" and getmetatable(node) == ast_node
end

local function ast_node_tostring(node, indent, hide)
  local newline = "\n"
  local spaces = string.rep("  ", indent)
  local spaces1 = string.rep("  ", indent + 1)
  if ast.is_node(node) then
    local hidden = node.node_type.print_hidden
    if hide and hidden then return end
    local collapsed = node.node_type.print_collapsed
    if collapsed then
      newline = ""
      spaces = ""
      spaces1 = ""
    end
    local str = tostring(node.node_type) .. "(" .. newline
    for k, v in pairs(node) do
      if k ~= "node_type" then
        local vstr = ast_node_tostring(v, indent + 1, hide)
        if vstr then
          str = str .. spaces1 .. k .. " = " .. vstr .. "," .. newline
        end
      end
    end
    return str .. spaces .. ")"
  elseif terralib.islist(node) then
    local str = "{" .. newline
    for i, v in ipairs(node) do
      local vstr = ast_node_tostring(v, indent + 1, hide)
      if vstr then
        str = str .. spaces1 .. vstr .. "," .. newline
      end
    end
    return str .. spaces .. "}"
  elseif type(node) == "string" then
    return string.format("%q", node)
  else
    return tostring(node)
  end
end

function ast_node:tostring(hide)
  if self.node_type.print_custom then
    if type(self.node_type.print_custom) == "string" then
      return self.node_type.print_custom
    else
      return self.node_type.print_custom(self)
    end
  else
    return ast_node_tostring(self, 0, hide)
  end
end

function ast_node:__tostring()
  return self:tostring(false)
end

function ast_node:printpretty(hide)
  print(self:tostring(hide))
end

function ast_node:is(node_type)
  return self.node_type:is(node_type)
end

function ast_node:type()
  return self.node_type
end

function ast_node:get_fields()
  local result = {}
  for k, v in pairs(self) do
    if k ~= "node_type" then
      result[k] = v
    end
  end
  return result
end

function ast_node:__call(fields_to_update)
  local ctor = rawget(self, "node_type")
  local values = {}
  for _, f in ipairs(ctor.expected_fields) do
    values[f] = self[f]
  end
  for f, v in pairs(fields_to_update) do
    if values[f] == nil then
      error(tostring(ctor) .. " does not require argument '" .. f .. "'", 2)
    end
    values[f] = v
  end
  return ctor(values)
end

-- Constructors

local ast_ctor = {}

function ast_ctor:__index(field)
  local value = ast_ctor[field]
  if value ~= nil then
    return value
  end
  error(tostring(self) .. " has no field '" .. field .. "'", 2)
end

function ast_ctor:set_memoize()
  assert(not self.memoize_cache)
  if #self.expected_fields > 0 then
    self.memoize_cache = {}
  else
    self.memoize_cache = self({})
  end
  return self
end

function ast_ctor:set_print_custom(thunk)
  assert(not self.print_custom)
  self.print_custom = thunk
  return self
end

function ast_ctor:__call(node)
  assert(type(node) == "table", tostring(self) .. " expected table")

  -- Normally, we assume we can co-opt the incoming table as the
  -- node. This is not true if the incoming node is itself an
  -- AST. (ASTs are not supposed to be mutable!) If so, copy the
  -- fields.
  local result = node
  if ast.is_node(node) then
    local copy = {}
    for k, v in pairs(node) do
      copy[k] = v
    end
    copy["node_type"] = nil
    result = copy
  end

  -- Check that the supplied fields are necessary and sufficient.
  for _, f in ipairs(self.expected_fields) do
    if rawget(result, f) == nil then
      error(tostring(self) .. " missing required argument '" .. f .. "'", 2)
    end
  end
  for f, _ in pairs(result) do
    if rawget(self.expected_field_set, f) == nil then
      error(tostring(self) .. " does not require argument '" .. f .. "'", 2)
    end
  end

  -- Prepare the result to be returned.
  rawset(result, "node_type", self)
  setmetatable(result, ast_node)

  if self.memoize_cache then
    local cache = self.memoize_cache
    for i, f in ipairs(self.expected_fields) do
      local value = rawget(result, f)
      if not cache[value] then
        if i < #self.expected_fields then
          cache[value] = {}
        else
          cache[value] = result
        end
      end
      cache = cache[value]
    end
    if cache then
      assert(cache:is(self))
      return cache
    end
  end

  return result
end

function ast_ctor:__tostring()
  return tostring(self.parent) .. "." .. self.name
end

function ast_ctor:is(node_type)
  return self == node_type or self.parent:is(node_type)
end

-- Factories

local function merge_fields(...)
  local keys = {}
  local result = terralib.newlist({})
  for _, fields in ipairs({...}) do
    if fields then
      for _, field in ipairs(fields) do
        if keys[field] then
          error("multiple definitions of field " .. field)
        end
        keys[field] = true
        result:insert(field)
      end
    end
  end
  return result
end

function ast_factory:__index(field)
  local value = ast_factory[field]
  if value ~= nil then
    return value
  end
  error(tostring(self) .. " has no field '" .. field .. "'", 2)
end

function ast_factory:inner(ctor_name, expected_fields, print_collapsed, print_hidden)
  local fields = merge_fields(self.expected_fields, expected_fields)
  local ctor = setmetatable(
    {
      parent = self,
      name = ctor_name,
      expected_fields = fields,
      expected_field_set = data.set(fields),
      print_collapsed = (print_collapsed == nil and self.print_collapsed) or print_collapsed or false,
      print_hidden = (print_hidden == nil and self.print_hidden) or print_hidden or false,
    }, ast_factory)

  assert(rawget(self, ctor_name) == nil,
         "multiple definitions of constructor " .. ctor_name)
  self[ctor_name] = ctor
  return ctor
end

function ast_factory:leaf(ctor_name, expected_fields, print_collapsed, print_hidden)
  local fields = merge_fields(self.expected_fields, expected_fields)
  local ctor = setmetatable(
    {
      parent = self,
      name = ctor_name,
      expected_fields = fields,
      expected_field_set = data.set(fields),
      print_collapsed = (print_collapsed == nil and self.print_collapsed) or print_collapsed or false,
      print_hidden = (print_hidden == nil and self.print_hidden) or print_hidden or false,
      print_custom = false,
      memoize_cache = false,
    }, ast_ctor)

  assert(rawget(self, ctor_name) == nil,
         "multiple definitions of constructor " .. ctor_name)
  self[ctor_name] = ctor
  return ctor
end

function ast_factory:is(node_type)
  return self == node_type or (self.parent and self.parent:is(node_type))
end

function ast_factory:__tostring()
  if self.parent then
    return tostring(self.parent) .. "." .. self.name
  end
  return self.name
end

-- Traversal

function ast.traverse_node_continuation(fn, node)
  local function continuation(node, continuing)
    if ast.is_node(node) then
      -- First entry: invoke the callback.
      if continuing == nil then
        fn(node, continuation)

      -- Second entry: (if true) continue to children.
      elseif continuing then
        for _, child in pairs(node) do
          continuation(child)
        end
      end
    elseif terralib.islist(node) then
      for _, child in ipairs(node) do
        continuation(child)
      end
    end
  end
  continuation(node)
end

function ast.map_node_continuation(fn, node)
  local function continuation(node, continuing)
    if ast.is_node(node) then
      -- First entry: invoke the callback.
      if continuing == nil then
        return fn(node, continuation)

      -- Second entry: (if true) continue to children.
      elseif continuing then
        local tmp = {}
        for k, child in pairs(node) do
          if k ~= "node_type" then
            tmp[k] = continuation(child)
          end
        end
        return node(tmp)
      end
    elseif terralib.islist(node) then
      local tmp = terralib.newlist()
      for _, child in ipairs(node) do
        tmp:insert(continuation(child))
      end
      return tmp
    end
    return node
  end
  return continuation(node)
end

function ast.flatmap_node_continuation(fn, node)
  local function continuation(node, continuing)
    if ast.is_node(node) then
      -- First entry: invoke the callback.
      if continuing == nil then
        return fn(node, continuation)

      -- Second entry: (if true) continue to children.
      elseif continuing then
        local tmp = {}
        for k, child in pairs(node) do
          if k ~= "node_type" then
            tmp[k] = continuation(child)
            assert(not terralib.islist(tmp[k]) or
                   terralib.islist(child) or
                   child:is(ast.unspecialized.stat) or
                   child:is(ast.specialized.stat) or
                   child:is(ast.typed.stat),
                   "flatmap only flattens a list of statements")
          end
        end
        return node(tmp)
      end
    elseif terralib.islist(node) then
      local tmp = terralib.newlist()
      for _, child in ipairs(node) do
        child = continuation(child)
        if terralib.islist(child) then
          tmp:insertall(child)
        else
          tmp:insert(child)
        end
      end
      return tmp
    end
    return node
  end
  return continuation(node)
end

function ast.traverse_node_postorder(fn, node)
  if ast.is_node(node) then
    for _, child in pairs(node) do
      ast.traverse_node_postorder(fn, child)
    end
    fn(node)
  elseif terralib.islist(node) then
    for _, child in ipairs(node) do
      ast.traverse_node_postorder(fn, child)
    end
  end
end

function ast.traverse_node_prepostorder(pre_fn, post_fn, node)
  if ast.is_node(node) then
    pre_fn(node)
    for k, child in pairs(node) do
      if k ~= "node_type" then
        ast.traverse_node_prepostorder(pre_fn, post_fn, child)
      end
    end
    post_fn(node)
  elseif terralib.islist(node) then
    for _, child in ipairs(node) do
      ast.traverse_node_prepostorder(pre_fn, post_fn, child)
    end
  end
end

function ast.map_node_postorder(fn, node)
  if ast.is_node(node) then
    local tmp = {}
    for k, child in pairs(node) do
      if k ~= "node_type" then
        tmp[k] = ast.map_node_postorder(fn, child)
      end
    end
    return fn(node(tmp))
  elseif terralib.islist(node) then
    local tmp = terralib.newlist()
    for _, child in ipairs(node) do
      tmp:insert(ast.map_node_postorder(fn, child))
    end
    return tmp
  end
  return node
end

function ast.map_node_prepostorder(pre_fn, post_fn, node)
  if ast.is_node(node) then
    local new_node = pre_fn(node)
    local tmp = {}
    for k, child in pairs(new_node) do
      if k ~= "node_type" then
        tmp[k] = ast.map_node_prepostorder(pre_fn, post_fn, child)
      end
    end
    return post_fn(new_node(tmp))
  elseif terralib.islist(node) then
    local tmp = terralib.newlist()
    for _, child in ipairs(node) do
      tmp:insert(ast.map_node_prepostorder(pre_fn, post_fn, child))
    end
    return tmp
  end
  return node
end

function ast.mapreduce_node_postorder(map_fn, reduce_fn, node, init)
  if ast.is_node(node) then
    local result = init
    for _, child in pairs(node) do
      result = reduce_fn(
        result,
        ast.mapreduce_node_postorder(map_fn, reduce_fn, child, init))
    end
    return reduce_fn(result, map_fn(node))
  elseif terralib.islist(node) then
    local result = init
    for _, child in ipairs(node) do
      result = reduce_fn(
        result,
        ast.mapreduce_node_postorder(map_fn, reduce_fn, child, init))
    end
    return result
  end
  return init
end

function ast.traverse_expr_postorder(fn, node)
  ast.traverse_node_postorder(
    function(child)
      if rawget(child, "expr_type") then
        fn(child)
      end
    end,
    node)
end

-- Location

ast:inner("location")
ast.location:leaf("Position", {"line", "offset"}, true)
ast.location:leaf("Span", {"source", "start", "stop"}, false, true)

-- Helpers for extracting location from token stream.
local function position_from_start(token)
  return ast.location.Position {
    line = token.linenumber,
    offset = token.offset
  }
end

local function position_from_stop(token)
  return position_from_start(token)
end

function ast.save(p)
  return position_from_start(p:cur())
end

function ast.span(start, p)
  return ast.location.Span {
    source = p.source,
    start = start,
    stop = position_from_stop(p:cur()),
  }
end

function ast.empty_span(p)
  return ast.location.Span {
    source = p.source,
    start = ast.location.Position { line = 0, offset = 0 },
    stop = ast.location.Position { line = 0, offset = 0 },
  }
end

function ast.trivial_span()
  return ast.location.Span {
    source = "",
    start = ast.location.Position { line = 0, offset = 0 },
    stop = ast.location.Position { line = 0, offset = 0 },
  }
end

-- Annotation

ast:inner("annotation")

-- Annotation: Dispositions
ast.annotation:leaf("Allow", {"value"}, true)
ast.annotation:leaf("Demand", {"value"}, true)
ast.annotation:leaf("Forbid", {"value"}, true)

-- Annotation: Values
ast.annotation:leaf("Unroll", {"value"}, true)

-- Annotation: Sets
ast.annotation:leaf("Set", {"cuda", "inline", "parallel", "spmd", "trace",
                            "vectorize"},
                    false, true)

function ast.default_annotations()
  local allow = ast.annotation.Allow { value = false }
  return ast.annotation.Set {
    cuda = allow,
    inline = allow,
    parallel = allow,
    spmd = allow,
    trace = allow,
    vectorize = allow,
  }
end

-- Kinds: Constraints, Privileges, Coherence, Flags, Conditions, Disjointness

ast:inner("constraint_kind")
ast.constraint_kind:leaf("Subregion"):set_memoize():set_print_custom("<=")
ast.constraint_kind:leaf("Disjointness"):set_memoize():set_print_custom("*")

ast:inner("privilege_kind")
ast.privilege_kind:leaf("Reads"):set_memoize():set_print_custom("reads")
ast.privilege_kind:leaf("Writes"):set_memoize():set_print_custom("writes")
ast.privilege_kind:leaf("Reduces", {"op"}):set_memoize():set_print_custom(
  function(node) return "reduces " .. tostring(node.op) end)

ast:inner("coherence_kind")
ast.coherence_kind:leaf("Exclusive"):set_memoize():set_print_custom("exclusive")
ast.coherence_kind:leaf("Atomic"):set_memoize():set_print_custom("atomic")
ast.coherence_kind:leaf("Simultaneous"):set_memoize():set_print_custom(
  "simultaneous")
ast.coherence_kind:leaf("Relaxed"):set_memoize():set_print_custom("relaxed")

ast:inner("flag_kind")
ast.flag_kind:leaf("NoAccessFlag"):set_memoize():set_print_custom(
  "no_access_flag")

ast:inner("condition_kind")
ast.condition_kind:leaf("Arrives"):set_memoize():set_print_custom("arrives")
ast.condition_kind:leaf("Awaits"):set_memoize():set_print_custom("awaits")

ast:inner("disjointness_kind")
ast.disjointness_kind:leaf("Aliased"):set_memoize():set_print_custom("aliased")
ast.disjointness_kind:leaf("Disjoint"):set_memoize():set_print_custom(
  "disjoint")

-- Constraints

ast:inner("constraint")
ast.constraint:leaf("Constraint", {"lhs", "rhs", "op"})

-- Privileges

ast:inner("privilege")
ast.privilege:leaf("Privilege", {"privilege", "region", "field_path"})

-- Node Types (Unspecialized)

ast:inner("unspecialized", {"span"})

ast.unspecialized:leaf("FieldNames", {"names_expr"})

ast.unspecialized:inner("region")
ast.unspecialized.region:leaf("Bare", {"region_name"})
ast.unspecialized.region:leaf("Root", {"region_name", "fields"})
ast.unspecialized.region:leaf("Field", {"field_name", "fields"})

ast.unspecialized:leaf("Constraint", {"lhs", "op", "rhs"})

ast.unspecialized:leaf("Privilege", {"privileges", "regions"})

ast.unspecialized:leaf("Coherence", {"coherence_modes", "regions"})

ast.unspecialized:leaf("Flag", {"flags", "regions"})

ast.unspecialized:leaf("ConditionVariable", {"name"})
ast.unspecialized:leaf("Condition", {"conditions", "variables"})

ast.unspecialized:leaf("Effect", {"expr"})

ast.unspecialized:inner("expr", {"annotations"})
ast.unspecialized.expr:leaf("ID", {"name"})
ast.unspecialized.expr:leaf("Escape", {"expr"})
ast.unspecialized.expr:leaf("FieldAccess", {"value", "field_names"})
ast.unspecialized.expr:leaf("IndexAccess", {"value", "index"})
ast.unspecialized.expr:leaf("MethodCall", {"value", "method_name", "args"})
ast.unspecialized.expr:leaf("Call", {"fn", "args", "conditions"})
ast.unspecialized.expr:leaf("Ctor", {"fields"})
ast.unspecialized.expr:leaf("CtorListField", {"value"})
ast.unspecialized.expr:leaf("CtorRecField", {"name_expr", "value"})
ast.unspecialized.expr:leaf("Constant", {"value", "expr_type"})
ast.unspecialized.expr:leaf("RawContext")
ast.unspecialized.expr:leaf("RawFields", {"region"})
ast.unspecialized.expr:leaf("RawPhysical", {"region"})
ast.unspecialized.expr:leaf("RawRuntime")
ast.unspecialized.expr:leaf("RawValue", {"value"})
ast.unspecialized.expr:leaf("Isnull", {"pointer"})
ast.unspecialized.expr:leaf("New", {"pointer_type_expr", "extent"})
ast.unspecialized.expr:leaf("Null", {"pointer_type_expr"})
ast.unspecialized.expr:leaf("DynamicCast", {"type_expr", "value"})
ast.unspecialized.expr:leaf("StaticCast", {"type_expr", "value"})
ast.unspecialized.expr:leaf("UnsafeCast", {"type_expr", "value"})
ast.unspecialized.expr:leaf("Ispace", {"index_type_expr", "extent", "start"})
ast.unspecialized.expr:leaf("Region", {"ispace", "fspace_type_expr"})
ast.unspecialized.expr:leaf("Partition", {"disjointness", "region", "coloring",
                                          "colors"})
ast.unspecialized.expr:leaf("PartitionEqual", {"region", "colors"})
ast.unspecialized.expr:leaf("PartitionByField", {"region", "colors"})
ast.unspecialized.expr:leaf("Image", {"parent", "partition", "region"})
ast.unspecialized.expr:leaf("Preimage", {"parent", "partition", "region"})
ast.unspecialized.expr:leaf("CrossProduct", {"args"})
ast.unspecialized.expr:leaf("CrossProductArray", {"lhs", "disjointness", "colorings"})
ast.unspecialized.expr:leaf("ListSlicePartition", {"partition", "indices"})
ast.unspecialized.expr:leaf("ListDuplicatePartition", {"partition", "indices"})
ast.unspecialized.expr:leaf("ListCrossProduct", {"lhs", "rhs", "shallow"})
ast.unspecialized.expr:leaf("ListCrossProductComplete", {"lhs", "product"})
ast.unspecialized.expr:leaf("ListPhaseBarriers", {"product"})
ast.unspecialized.expr:leaf("ListInvert", {"rhs", "product", "barriers"})
ast.unspecialized.expr:leaf("ListRange", {"start", "stop"})
ast.unspecialized.expr:leaf("ListIspace", {"ispace"})
ast.unspecialized.expr:leaf("PhaseBarrier", {"value"})
ast.unspecialized.expr:leaf("DynamicCollective", {"value_type_expr", "op", "arrivals"})
ast.unspecialized.expr:leaf("DynamicCollectiveGetResult", {"value"})
ast.unspecialized.expr:leaf("Advance", {"value"})
ast.unspecialized.expr:leaf("Arrive", {"barrier", "value"})
ast.unspecialized.expr:leaf("Await", {"barrier"})
ast.unspecialized.expr:leaf("Copy", {"src", "dst", "op", "conditions"})
ast.unspecialized.expr:leaf("Fill", {"dst", "value", "conditions"})
ast.unspecialized.expr:leaf("Acquire", {"region", "conditions"})
ast.unspecialized.expr:leaf("Release", {"region", "conditions"})
ast.unspecialized.expr:leaf("AllocateScratchFields", {"region"})
ast.unspecialized.expr:leaf("WithScratchFields", {"region", "field_ids"})
ast.unspecialized.expr:leaf("RegionRoot", {"region", "fields"})
ast.unspecialized.expr:leaf("Condition", {"conditions", "values"})
ast.unspecialized.expr:leaf("Unary", {"op", "rhs"})
ast.unspecialized.expr:leaf("Binary", {"op", "lhs", "rhs"})
ast.unspecialized.expr:leaf("Deref", {"value"})

ast.unspecialized:leaf("Block", {"stats"})

ast.unspecialized:inner("stat", {"annotations"})
ast.unspecialized.stat:leaf("If", {"cond", "then_block", "elseif_blocks",
                                   "else_block"})
ast.unspecialized.stat:leaf("Elseif", {"cond", "block"})
ast.unspecialized.stat:leaf("While", {"cond", "block"})
ast.unspecialized.stat:leaf("ForNum", {"name", "type_expr", "values", "block"})
ast.unspecialized.stat:leaf("ForList", {"name", "type_expr", "value", "block"})
ast.unspecialized.stat:leaf("Repeat", {"block", "until_cond"})
ast.unspecialized.stat:leaf("MustEpoch", {"block"})
ast.unspecialized.stat:leaf("Block", {"block"})
ast.unspecialized.stat:leaf("Var", {"var_names", "type_exprs", "values"})
ast.unspecialized.stat:leaf("VarUnpack", {"var_names", "fields", "value"})
ast.unspecialized.stat:leaf("Return", {"value"})
ast.unspecialized.stat:leaf("Break")
ast.unspecialized.stat:leaf("Assignment", {"lhs", "rhs"})
ast.unspecialized.stat:leaf("Reduce", {"op", "lhs", "rhs"})
ast.unspecialized.stat:leaf("Expr", {"expr"})
ast.unspecialized.stat:leaf("Escape", {"expr"})
ast.unspecialized.stat:leaf("RawDelete", {"value"})

ast.unspecialized:inner("top", {"annotations"})
ast.unspecialized.top:leaf("Task", {"name", "params", "return_type_expr",
                                    "effect_exprs", "body"})
ast.unspecialized.top:leaf("TaskParam", {"param_name", "type_expr"})
ast.unspecialized.top:leaf("Fspace", {"name", "params", "fields",
                                      "constraints"})
ast.unspecialized.top:leaf("FspaceParam", {"param_name", "type_expr"})
ast.unspecialized.top:leaf("FspaceField", {"field_name", "type_expr"})
ast.unspecialized.top:leaf("QuoteExpr", {"expr"})
ast.unspecialized.top:leaf("QuoteStat", {"block"})


-- Node Types (Specialized)

ast:inner("specialized", {"span"})

ast.specialized:inner("region")
ast.specialized.region:leaf("Bare", {"symbol"})
ast.specialized.region:leaf("Root", {"symbol", "fields"})
ast.specialized.region:leaf("Field", {"field_name", "fields"})

ast.specialized:leaf("Constraint", {"lhs", "op", "rhs"})

ast.specialized:leaf("Privilege", {"privileges", "regions"})

ast.specialized:leaf("Coherence", {"coherence_modes", "regions"})

ast.specialized:leaf("Flag", {"flags", "regions"})

ast.specialized:leaf("ConditionVariable", {"symbol"})
ast.specialized:leaf("Condition", {"conditions", "variables"})

ast.specialized:inner("expr", {"annotations"})
ast.specialized.expr:leaf("ID", {"value"})
ast.specialized.expr:leaf("FieldAccess", {"value", "field_name"})
ast.specialized.expr:leaf("IndexAccess", {"value", "index"})
ast.specialized.expr:leaf("MethodCall", {"value", "method_name", "args"})
ast.specialized.expr:leaf("Call", {"fn", "args", "conditions"})
ast.specialized.expr:leaf("Cast", {"fn", "args"})
ast.specialized.expr:leaf("Ctor", {"fields", "named"})
ast.specialized.expr:leaf("CtorListField", {"value"})
ast.specialized.expr:leaf("CtorRecField", {"name", "value"})
ast.specialized.expr:leaf("Constant", {"value", "expr_type"})
ast.specialized.expr:leaf("RawContext")
ast.specialized.expr:leaf("RawFields", {"region"})
ast.specialized.expr:leaf("RawPhysical", {"region"})
ast.specialized.expr:leaf("RawRuntime")
ast.specialized.expr:leaf("RawValue", {"value"})
ast.specialized.expr:leaf("Isnull", {"pointer"})
ast.specialized.expr:leaf("New", {"pointer_type", "region", "extent"})
ast.specialized.expr:leaf("Null", {"pointer_type"})
ast.specialized.expr:leaf("DynamicCast", {"value", "expr_type"})
ast.specialized.expr:leaf("StaticCast", {"value", "expr_type"})
ast.specialized.expr:leaf("UnsafeCast", {"value", "expr_type"})
ast.specialized.expr:leaf("Ispace", {"index_type", "extent", "start"})
ast.specialized.expr:leaf("Region", {"ispace", "fspace_type"})
ast.specialized.expr:leaf("Partition", {"disjointness", "region", "coloring",
                                        "colors"})
ast.specialized.expr:leaf("PartitionEqual", {"region", "colors"})
ast.specialized.expr:leaf("PartitionByField", {"region", "colors"})
ast.specialized.expr:leaf("Image", {"parent", "partition", "region"})
ast.specialized.expr:leaf("Preimage", {"parent", "partition", "region"})
ast.specialized.expr:leaf("CrossProduct", {"args"})
ast.specialized.expr:leaf("CrossProductArray", {"lhs", "disjointness", "colorings"})
ast.specialized.expr:leaf("ListSlicePartition", {"partition", "indices"})
ast.specialized.expr:leaf("ListDuplicatePartition", {"partition", "indices"})
ast.specialized.expr:leaf("ListCrossProduct", {"lhs", "rhs", "shallow"})
ast.specialized.expr:leaf("ListCrossProductComplete", {"lhs", "product"})
ast.specialized.expr:leaf("ListPhaseBarriers", {"product"})
ast.specialized.expr:leaf("ListInvert", {"rhs", "product", "barriers"})
ast.specialized.expr:leaf("ListRange", {"start", "stop"})
ast.specialized.expr:leaf("ListIspace", {"ispace"})
ast.specialized.expr:leaf("PhaseBarrier", {"value"})
ast.specialized.expr:leaf("DynamicCollective", {"value_type", "op", "arrivals"})
ast.specialized.expr:leaf("DynamicCollectiveGetResult", {"value"})
ast.specialized.expr:leaf("Advance", {"value"})
ast.specialized.expr:leaf("Arrive", {"barrier", "value"})
ast.specialized.expr:leaf("Await", {"barrier"})
ast.specialized.expr:leaf("Copy", {"src", "dst", "op", "conditions"})
ast.specialized.expr:leaf("Fill", {"dst", "value", "conditions"})
ast.specialized.expr:leaf("Acquire", {"region", "conditions"})
ast.specialized.expr:leaf("Release", {"region", "conditions"})
ast.specialized.expr:leaf("AllocateScratchFields", {"region"})
ast.specialized.expr:leaf("WithScratchFields", {"region", "field_ids"})
ast.specialized.expr:leaf("RegionRoot", {"region", "fields"})
ast.specialized.expr:leaf("Condition", {"conditions", "values"})
ast.specialized.expr:leaf("Function", {"value"})
ast.specialized.expr:leaf("Unary", {"op", "rhs"})
ast.specialized.expr:leaf("Binary", {"op", "lhs", "rhs"})
ast.specialized.expr:leaf("Deref", {"value"})
ast.specialized.expr:leaf("LuaTable", {"value"})

ast.specialized:leaf("Block", {"stats"})

ast.specialized:inner("stat", {"annotations"})
ast.specialized.stat:leaf("If", {"cond", "then_block", "elseif_blocks",
                                 "else_block"})
ast.specialized.stat:leaf("Elseif", {"cond", "block"})
ast.specialized.stat:leaf("While", {"cond", "block"})
ast.specialized.stat:leaf("ForNum", {"symbol", "values", "block"})
ast.specialized.stat:leaf("ForList", {"symbol", "value", "block"})
ast.specialized.stat:leaf("Repeat", {"block", "until_cond"})
ast.specialized.stat:leaf("MustEpoch", {"block"})
ast.specialized.stat:leaf("Block", {"block"})
ast.specialized.stat:leaf("Var", {"symbols", "values"})
ast.specialized.stat:leaf("VarUnpack", {"symbols", "fields", "value"})
ast.specialized.stat:leaf("Return", {"value"})
ast.specialized.stat:leaf("Break")
ast.specialized.stat:leaf("Assignment", {"lhs", "rhs"})
ast.specialized.stat:leaf("Reduce", {"op", "lhs", "rhs"})
ast.specialized.stat:leaf("Expr", {"expr"})
ast.specialized.stat:leaf("RawDelete", {"value"})

ast.specialized:inner("top", {"annotations"})
ast.specialized.top:leaf("Task", {"name", "params", "return_type",
                                  "privileges", "coherence_modes", "flags",
                                  "conditions", "constraints", "body",
                                  "prototype"})
ast.specialized.top:leaf("TaskParam", {"symbol"})
ast.specialized.top:leaf("Fspace", {"name", "fspace", "constraints"})
ast.specialized.top:leaf("QuoteExpr", {"expr"})
ast.specialized.top:leaf("QuoteStat", {"block"})


-- Node Types (Typed)

ast.typed = ast:inner("typed", {"span"})

ast.typed:inner("expr", {"annotations", "expr_type"})
ast.typed.expr:leaf("Internal", {"value"}) -- internal use only

ast.typed.expr:leaf("ID", {"value"})
ast.typed.expr:leaf("FieldAccess", {"value", "field_name"})
ast.typed.expr:leaf("IndexAccess", {"value", "index"})
ast.typed.expr:leaf("MethodCall", {"value", "method_name", "args"})
ast.typed.expr:leaf("Call", {"fn", "args", "conditions"})
ast.typed.expr:leaf("Cast", {"fn", "arg"})
ast.typed.expr:leaf("Ctor", {"fields", "named"})
ast.typed.expr:leaf("CtorListField", {"value"})
ast.typed.expr:leaf("CtorRecField", {"name", "value"})
ast.typed.expr:leaf("RawContext")
ast.typed.expr:leaf("RawFields", {"region", "fields"})
ast.typed.expr:leaf("RawPhysical", {"region", "fields"})
ast.typed.expr:leaf("RawRuntime")
ast.typed.expr:leaf("RawValue", {"value"})
ast.typed.expr:leaf("Isnull", {"pointer"})
ast.typed.expr:leaf("New", {"pointer_type", "region", "extent"})
ast.typed.expr:leaf("Null", {"pointer_type"})
ast.typed.expr:leaf("DynamicCast", {"value"})
ast.typed.expr:leaf("StaticCast", {"value", "parent_region_map"})
ast.typed.expr:leaf("UnsafeCast", {"value"})
ast.typed.expr:leaf("Ispace", {"index_type", "extent", "start"})
ast.typed.expr:leaf("Region", {"ispace", "fspace_type"})
ast.typed.expr:leaf("Partition", {"disjointness", "region", "coloring",
                                  "colors"})
ast.typed.expr:leaf("PartitionEqual", {"region", "colors"})
ast.typed.expr:leaf("PartitionByField", {"region", "colors"})
ast.typed.expr:leaf("Image", {"parent", "partition", "region"})
ast.typed.expr:leaf("Preimage", {"parent", "partition", "region"})
ast.typed.expr:leaf("CrossProduct", {"args"})
ast.typed.expr:leaf("CrossProductArray", {"lhs", "disjointness", "colorings"})
ast.typed.expr:leaf("ListSlicePartition", {"partition", "indices"})
ast.typed.expr:leaf("ListDuplicatePartition", {"partition", "indices"})
ast.typed.expr:leaf("ListSliceCrossProduct", {"product", "indices"})
ast.typed.expr:leaf("ListCrossProduct", {"lhs", "rhs", "shallow"})
ast.typed.expr:leaf("ListCrossProductComplete", {"lhs", "product"})
ast.typed.expr:leaf("ListPhaseBarriers", {"product"})
ast.typed.expr:leaf("ListInvert", {"rhs", "product", "barriers"})
ast.typed.expr:leaf("ListRange", {"start", "stop"})
ast.typed.expr:leaf("ListIspace", {"ispace"})
ast.typed.expr:leaf("PhaseBarrier", {"value"})
ast.typed.expr:leaf("DynamicCollective", {"value_type", "op", "arrivals"})
ast.typed.expr:leaf("DynamicCollectiveGetResult", {"value"})
ast.typed.expr:leaf("Advance", {"value"})
ast.typed.expr:leaf("Arrive", {"barrier", "value"})
ast.typed.expr:leaf("Await", {"barrier"})
ast.typed.expr:leaf("Copy", {"src", "dst", "op", "conditions"})
ast.typed.expr:leaf("Fill", {"dst", "value", "conditions"})
ast.typed.expr:leaf("Acquire", {"region", "conditions"})
ast.typed.expr:leaf("Release", {"region", "conditions"})
ast.typed.expr:leaf("AllocateScratchFields", {"region"})
ast.typed.expr:leaf("WithScratchFields", {"region", "field_ids"})
ast.typed.expr:leaf("RegionRoot", {"region", "fields"})
ast.typed.expr:leaf("Condition", {"conditions", "value"})
ast.typed.expr:leaf("Constant", {"value"})
ast.typed.expr:leaf("Function", {"value"})
ast.typed.expr:leaf("Unary", {"op", "rhs"})
ast.typed.expr:leaf("Binary", {"op", "lhs", "rhs"})
ast.typed.expr:leaf("Deref", {"value"})
ast.typed.expr:leaf("Future", {"value"})
ast.typed.expr:leaf("FutureGetResult", {"value"})

ast.typed:leaf("Block", {"stats"})

ast.typed:inner("stat", {"annotations"})
ast.typed.stat:leaf("Internal", {"actions"}) -- internal use only
ast.typed.stat:leaf("If", {"cond", "then_block", "elseif_blocks", "else_block"})
ast.typed.stat:leaf("Elseif", {"cond", "block"})
ast.typed.stat:leaf("While", {"cond", "block"})
ast.typed.stat:leaf("ForNum", {"symbol", "values", "block"})
ast.typed.stat:leaf("ForList", {"symbol", "value", "block"})
ast.typed.stat:leaf("ForListVectorized", {"symbol", "value", "block",
                                          "orig_block", "vector_width"})
ast.typed.stat:leaf("Repeat", {"block", "until_cond"})
ast.typed.stat:leaf("MustEpoch", {"block"})
ast.typed.stat:leaf("Block", {"block"})
ast.typed.stat:leaf("IndexLaunchNum", {"symbol", "values", "preamble", "call",
                                       "reduce_lhs", "reduce_op",
                                       "args_provably"})
ast.typed.stat:leaf("IndexLaunchList", {"symbol", "value", "preamble", "call",
                                        "reduce_lhs", "reduce_op",
                                        "args_provably"})
ast:leaf("IndexLaunchArgsProvably", {"invariant", "variant"})
ast.typed.stat:leaf("Var", {"symbols", "types", "values"})
ast.typed.stat:leaf("VarUnpack", {"symbols", "fields", "field_types", "value"})
ast.typed.stat:leaf("Return", {"value"})
ast.typed.stat:leaf("Break")
ast.typed.stat:leaf("Assignment", {"lhs", "rhs"})
ast.typed.stat:leaf("Reduce", {"op", "lhs", "rhs"})
ast.typed.stat:leaf("Expr", {"expr"})
ast.typed.stat:leaf("RawDelete", {"value"})
ast.typed.stat:leaf("BeginTrace", {"trace_id"})
ast.typed.stat:leaf("EndTrace", {"trace_id"})
ast.typed.stat:leaf("MapRegions", {"region_types"})
ast.typed.stat:leaf("UnmapRegions", {"region_types"})

ast:leaf("TaskConfigOptions", {"leaf", "inner", "idempotent"})

ast.typed:inner("top", {"annotations"})
ast.typed.top:leaf("Fspace", {"name", "fspace"})
ast.typed.top:leaf("Task", {"name", "params", "return_type", "privileges",
                             "coherence_modes", "flags", "conditions",
                             "constraints", "body", "config_options",
                             "region_divergence", "prototype"})
ast.typed.top:leaf("TaskParam", {"symbol", "param_type"})

return ast
