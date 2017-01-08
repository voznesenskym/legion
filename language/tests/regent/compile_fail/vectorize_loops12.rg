-- Copyright 2017 Stanford University
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

-- fails-with:
-- vectorize_loops12.rg:28: vectorization failed: loop body has a new expression
--     var p = new(ptr(int, r2))
--                   ^

import "regent"

task toplevel()
  var n = 8
  var r = region(ispace(ptr, n), int)
  var r2 = region(ispace(ptr, n), int)
  __demand(__vectorize)
  for e in r do
    var p = new(ptr(int, r2))
  end
end

regentlib.start(toplevel)
