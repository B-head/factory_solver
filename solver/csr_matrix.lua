---Implementation of compressed sparse row matrix.
---@license MIT
---@author B_head

---@class CsrMatrix
---@field width integer
---@field values number[]
---@field column_indexes integer[]
---@field row_ranges integer[]
local M = {}

local metatable = { __index = M }

local int_max = 2147483647

---Setup metatable.
---@param self CsrMatrix
---@return CsrMatrix
function M.setup_metatable(self)
    return setmetatable(self, metatable)
end

---comment
---@param width integer
---@param values number[]
---@param column_indexes integer[]
---@param row_ranges integer[]
---@return CsrMatrix
function M.new(width, values, column_indexes, row_ranges)
    local self = {
        width = width,
        values = values,
        column_indexes = column_indexes,
        row_ranges = row_ranges,
    }
    return M.setup_metatable(self)
end

---comment
---@param matrix number[][]
---@return CsrMatrix
function M.from_matrix(matrix)
    local width = 0
    local values = {}
    local column_indexes = {}
    local row_ranges = { 1 }

    local t = 1
    for y = 1, #matrix do
        local list = matrix[y]
        local w = #list
        if width < w then
            width = w
        end

        for x = 1, w do
            local a = list[x]
            if a ~= 0 then
                values[t] = a
                column_indexes[t] = x
                t = t + 1
            end
        end

        row_ranges[y + 1] = t
    end

    return M.new(width, values, column_indexes, row_ranges)
end

---comment
---@param width integer
---@param list_of_values number[][]
---@param list_of_column_indexes number[][]
---@return CsrMatrix
function M.from_list_of_list(width, list_of_values, list_of_column_indexes)
    local values = {}
    local column_indexes = {}
    local row_ranges = { 1 }

    local t = 1
    for y = 1, #list_of_values do
        local v = list_of_values[y]
        local c = list_of_column_indexes[y]
        for i = 1, #v do
            local a = v[i]
            if a ~= 0 then
                values[t] = a
                column_indexes[t] = c[i]
                t = t + 1
            end
        end

        row_ranges[y + 1] = t
    end

    return M.new(width, values, column_indexes, row_ranges)
end

---comment
---@param width integer
---@param coordinate_list { x: integer, y: integer, value: number }[]
---@return CsrMatrix
function M.from_coordinate_list(width, coordinate_list)
    table.sort(coordinate_list, function(a, b)
        if a.y == b.y then
            return a.x < b.x
        else
            return a.y < b.y
        end
    end)

    local values = {}
    local column_indexes = {}
    local row_ranges = { 1 }

    local length = #coordinate_list
    local prev_y = 1
    for i = 1, length do
        local a = coordinate_list[i]
        if prev_y < a.y then
            prev_y = prev_y + 1
            row_ranges[prev_y] = i
        end
        values[i] = a.value
        column_indexes[i] = a.x
    end

    row_ranges[prev_y + 1] = length + 1

    return M.new(width, values, column_indexes, row_ranges)
end

---comment
---@param list number[] | number
---@param length integer?
---@return CsrMatrix
function M.with_vector(list, length)
    length = length or #list

    local values = {}
    local column_indexes = {}
    local row_ranges = { 1 }
    local is_list = type(list) == "table"

    local t = 1
    for i = 1, length do
        local a = (is_list) and list[i] or list
        if a ~= 0 then
            values[t] = a
            column_indexes[t] = 1
            t = t + 1
        end
        row_ranges[i + 1] = t
    end

    return M.new(1, values, column_indexes, row_ranges)
end

---comment
---@param list number[] | number
---@param length integer?
---@return CsrMatrix
function M.with_diagonal(list, length)
    length = length or #list

    local values = {}
    local column_indexes = {}
    local row_ranges = { 1 }
    local is_list = type(list) == "table"

    local t = 1
    for i = 1, length do
        local a = (is_list) and list[i] or list
        if a ~= 0 then
            values[t] = a
            column_indexes[t] = i
            t = t + 1
        end
        row_ranges[i + 1] = t
    end

    return M.new(#list, values, column_indexes, row_ranges)
end

---comment
---@param matrix CsrMatrix
---@return string
function metatable.__tostring(matrix)
    local width = matrix.width
    local values = matrix.values
    local column_indexes = matrix.column_indexes
    local row_ranges = matrix.row_ranges
    local ret = {} ---@type string[]

    for y = 1, #row_ranges - 1 do
        if y ~= 1 then
            table.insert(ret, "\n")
        end

        local i = row_ranges[y]
        local ie = row_ranges[y + 1]
        local u = (i < ie) and column_indexes[i] or int_max

        for x = 1, width do
            local a = 0
            if x == u then
                a = values[i]
                i = i + 1
                u = (i < ie) and column_indexes[i] or int_max
            end
            table.insert(ret, string.format("%13g", a))
        end
    end

    table.insert(ret, " .")
    return table.concat(ret)
end

---comment
---@param op1 CsrMatrix
---@param op2 CsrMatrix
---@param func fun(a: number, b: number):number
---@return CsrMatrix
local function broadcast(op1, op2, func)
    assert(op1.width == op2.width)
    assert(#op1.row_ranges == #op2.row_ranges)

    local values = {}
    local column_indexes = {}
    local row_ranges = { 1 }

    local op1_values = op1.values
    local op1_column_indexes = op1.column_indexes
    local op1_row_ranges = op1.row_ranges
    local op2_values = op2.values
    local op2_column_indexes = op2.column_indexes
    local op2_row_ranges = op2.row_ranges

    local t = 1
    for y = 1, #op1_row_ranges - 1 do
        local i, ie = op1_row_ranges[y], op1_row_ranges[y + 1]
        local k, ke = op2_row_ranges[y], op2_row_ranges[y + 1]
        local u = (i < ie) and op1_column_indexes[i] or int_max
        local v = (k < ke) and op2_column_indexes[k] or int_max

        while not (u == int_max and v == int_max) do
            local a, b, w = 0, 0, u

            if w <= v then
                a = op1_values[i]
                i = i + 1
                u = (i < ie) and op1_column_indexes[i] or int_max
            end

            if w >= v then
                w = v
                b = op2_values[k]
                k = k + 1
                v = (k < ke) and op2_column_indexes[k] or int_max
            end

            local c = func(a, b)
            if c ~= 0 then
                values[t] = c
                column_indexes[t] = w
                t = t + 1
            end
        end

        row_ranges[y + 1] = t
    end

    return M.new(op1.width, values, column_indexes, row_ranges)
end

---comment
---@param op1 CsrMatrix
---@param op2 CsrMatrix
---@return CsrMatrix
function metatable.__add(op1, op2)
    return broadcast(op1, op2, function(a, b) return a + b end)
end

---comment
---@param op1 CsrMatrix
---@param op2 CsrMatrix
---@return CsrMatrix
function metatable.__sub(op1, op2)
    return broadcast(op1, op2, function(a, b) return a - b end)
end

---comment
---@param op1 CsrMatrix | number
---@param op2 CsrMatrix | number
---@return CsrMatrix
function metatable.__mul(op1, op2)
    if type(op1) == "number" then
        op1, op2 = op2, op1
    end

    if type(op2) == "number" then
        local values = {}
        local op1_values = op1.values

        for i = 1, #op1_values do
            values[i] = op1_values[i] * op2
        end

        return M.new(op1.width, values, op1.column_indexes, op1.row_ranges)
    end

    assert(op1.width == #op2.row_ranges - 1)

    local width = op2.width
    local values = {}
    local column_indexes = {}
    local row_ranges = { 1 }

    local op1_values = op1.values
    local op1_column_indexes = op1.column_indexes
    local op1_row_ranges = op1.row_ranges
    local op2_values = op2.values
    local op2_column_indexes = op2.column_indexes
    local op2_row_ranges = op2.row_ranges

    local temp_values = {}
    for x = 1, width do
        temp_values[x] = 0
    end

    local t = 1
    for y = 1, #op1_row_ranges - 1 do
        for i = op1_row_ranges[y], op1_row_ranges[y + 1] - 1 do
            local u = op1_column_indexes[i]
            for k = op2_row_ranges[u], op2_row_ranges[u + 1] - 1 do
                local v = op2_column_indexes[k]
                temp_values[v] = temp_values[v] + op1_values[i] * op2_values[k]
            end
        end

        for x = 1, width do
            local a = temp_values[x]
            if a ~= 0 then
                temp_values[x] = 0
                values[t] = a
                column_indexes[t] = x
                t = t + 1
            end
        end

        row_ranges[y + 1] = t
    end

    return M.new(width, values, column_indexes, row_ranges)
end

---comment
---@param op1 CsrMatrix
---@param op2 number
---@return CsrMatrix
function metatable.__div(op1, op2)
    local values = {}
    local op1_values = op1.values

    for i = 1, #op1_values do
        values[i] = op1_values[i] / op2
    end

    return M.new(op1.width, values, op1.column_indexes, op1.row_ranges)
end

---comment
---@param op1 CsrMatrix
---@return CsrMatrix
function metatable.__unm(op1)
    local values = {}
    local op1_values = op1.values

    for i = 1, #op1_values do
        values[i] = -op1_values[i]
    end

    return M.new(op1.width, values, op1.column_indexes, op1.row_ranges)
end

---comment
---@param op1 CsrMatrix
---@param op2 CsrMatrix
---@return CsrMatrix
function M.hadamard_product(op1, op2)
    return broadcast(op1, op2, function(a, b) return a * b end)
end

---comment
---@param op1 CsrMatrix
---@param op2 CsrMatrix
---@return CsrMatrix
function M.hadamard_division(op1, op2)
    return broadcast(op1, op2, function(a, b) return a / b end)
end

---comment
---@param op1 CsrMatrix
---@param op2 number
---@return CsrMatrix
function M.hadamard_power(op1, op2)
    local values = {}
    local op1_values = op1.values

    for i = 1, #op1_values do
        values[i] = op1_values[i] ^ op2
    end

    return M.new(op1.width, values, op1.column_indexes, op1.row_ranges)
end

---comment
---@param op1 CsrMatrix
---@return CsrMatrix
function M.T(op1)
    local list_of_values = {}
    local list_of_column_indexes = {}

    local op1_width = op1.width
    local op1_values = op1.values
    local op1_column_indexes = op1.column_indexes
    local op1_row_ranges = op1.row_ranges
    local op1_height = #op1_row_ranges - 1

    local temp_indexes = {}
    for x = 1, op1_width do
        temp_indexes[x] = 1
        list_of_values[x] = {}
        list_of_column_indexes[x] = {}
    end

    for y = 1, op1_height do
        for i = op1_row_ranges[y], op1_row_ranges[y + 1] - 1 do
            local u = op1_column_indexes[i]
            local t = temp_indexes[u]
            list_of_values[u][t] = op1_values[i]
            list_of_column_indexes[u][t] = y
            temp_indexes[u] = t + 1
        end
    end

    return M.from_list_of_list(op1_height, list_of_values, list_of_column_indexes)
end

---comment
---@param op1 CsrMatrix
---@param min_value number
---@param max_value number
---@return CsrMatrix
function M.clamp(op1, min_value, max_value)
    local values = {}
    local op1_values = op1.values
    local min, max = math.min, math.max

    for i = 1, #op1_values do
        values[i] = max(min_value, min(op1_values[i], max_value))
    end

    return M.new(op1.width, values, op1.column_indexes, op1.row_ranges)
end

---comment
---@param vector CsrMatrix
---@param initial number?
---@param func fun(a: number, b: number):number
---@return number
function M.fold(vector, initial, func)
    assert(vector.width == 1)

    local values = vector.values
    local ret = initial or 0
    for i = 1, #values do
        ret = func(ret, values[i])
    end

    return ret
end

---comment
---@param vector CsrMatrix
---@return number
function M.euclidean_norm(vector)
    return math.sqrt(M.fold(vector, 0, function(a, b)
        return a + b ^ 2
    end))
end

---comment
---@param vector CsrMatrix
---@return CsrMatrix
function M.diag(vector)
    assert(vector.width == 1)

    local row_ranges = vector.row_ranges
    local column_indexes = {}
    local i = 1
    for y = 1, #row_ranges - 1 do
        if row_ranges[y] ~= row_ranges[y + 1] then
            column_indexes[i] = y
            i = i + 1
        end
    end

    return M.new(#vector.row_ranges - 1, vector.values, column_indexes, vector.row_ranges)
end

---comment
---@param vector CsrMatrix
---@return number[]
function M.to_list(vector)
    assert(vector.width == 1)

    local values = vector.values
    local row_ranges = vector.row_ranges
    local ret = {}
    local i = 1
    for y = 1, #row_ranges - 1 do
        if row_ranges[y] == row_ranges[y + 1] then
            ret[y] = 0
        else
            ret[y] = values[i]
            i = i + 1
        end
    end

    return ret
end

---comment
---@param matrix CsrMatrix
---@return number[][]
function M.to_matrix(matrix)
    local ret = {}

    local width = matrix.width
    local values = matrix.values
    local column_indexes = matrix.column_indexes
    local row_ranges = matrix.row_ranges

    for y = 1, #row_ranges - 1 do
        local a, i, ie = {}, row_ranges[y], row_ranges[y + 1]
        local u = (i < ie) and column_indexes[i] or int_max
        for x = 1, width do
            if x == u then
                a[x] = values[i]
                i = i + 1
                u = (i < ie) and column_indexes[i] or int_max
            else
                a[x] = 0
            end
        end
        ret[y] = a
    end

    return ret
end

---comment
---@param matrix CsrMatrix
---@return integer
---@return number[][]
---@return number[][]
function M.to_list_of_list(matrix)
    local list_of_values = {}
    local list_of_column_indexes = {}

    local values = matrix.values
    local column_indexes = matrix.column_indexes
    local row_ranges = matrix.row_ranges

    for y = 1, #row_ranges - 1 do
        local v, c, t = {}, {}, 1
        for i = row_ranges[y], row_ranges[y + 1] - 1 do
            v[t] = values[i]
            c[t] = column_indexes[i]
            t = t + 1
        end
        list_of_values[y] = v
        list_of_column_indexes[y] = c
    end

    return matrix.width, list_of_values, list_of_column_indexes
end

---LDL decomposition of the symmetric matrix.
---@param symmetric_matrix CsrMatrix
---@return CsrMatrix, CsrMatrix
function M.cholesky_decomposition(symmetric_matrix)
    local values = {}
    local column_indexes = {}
    local row_ranges = { 1 }
    local diagonal = {}

    local origin_values = symmetric_matrix.values
    local origin_column_indexes = symmetric_matrix.column_indexes
    local origin_row_ranges = symmetric_matrix.row_ranges
    local origin_height = #origin_row_ranges - 1

    local t, dt = 1, 1
    for y = 1, origin_height do
        local m, me = origin_row_ranges[y], origin_row_ranges[y + 1]
        local oc = (m < me) and origin_column_indexes[m] or int_max

        for x = 1, y - 1 do
            local i, ie = row_ranges[y], t
            local k, ke = row_ranges[x], row_ranges[x + 1]
            local u = (i < ie) and column_indexes[i] or int_max
            local v = (k < ke) and column_indexes[k] or int_max

            local sum = 0
            while u < x or v < x do
                local a, b, w = 0, 0, u

                if w <= v then
                    a = values[i]
                    i = i + 1
                    u = (i < ie) and column_indexes[i] or int_max
                end

                if w >= v then
                    w = v
                    b = values[k]
                    k = k + 1
                    v = (k < ke) and column_indexes[k] or int_max
                end

                sum = sum + a * b * diagonal[w]
            end

            local ov = 0
            if oc == x then
                ov = origin_values[m]
                m = m + 1
                oc = (m < me) and origin_column_indexes[m] or int_max
            end

            local c = (ov - sum) / diagonal[x]
            if c ~= 0 then
                values[t] = c
                column_indexes[t] = x
                t = t + 1
            end
        end

        values[t] = 1
        column_indexes[t] = y
        t = t + 1
        row_ranges[y + 1] = t

        local sum = 0
        for i = row_ranges[y], t - 1 do
            local u = column_indexes[i]
            if u < y then
                sum = sum + values[i] ^ 2 * diagonal[u]
            else
                local ov = 0
                if oc == y then
                    ov = origin_values[m]
                    m = m + 1
                    oc = (m < me) and origin_column_indexes[m] or int_max
                end

                diagonal[dt] = ov - sum
                dt = dt + 1
                break
            end
        end
    end

    return M.new(symmetric_matrix.width, values, column_indexes, row_ranges),
        M.with_diagonal(diagonal, origin_height)
end

---Use lower triangular matrix to solve linear equations.
---@param lower_triangular_matrix CsrMatrix
---@param augment_column CsrMatrix
---@return CsrMatrix
function M.forward_substitution(lower_triangular_matrix, augment_column)
    local solved, augment_column_list = {}, M.to_list(augment_column)

    local values = lower_triangular_matrix.values
    local column_indexes = lower_triangular_matrix.column_indexes
    local row_ranges = lower_triangular_matrix.row_ranges
    local height = #row_ranges - 1

    for y = 1, height do
        local sum = 0
        local is, ie = row_ranges[y], row_ranges[y + 1]
        for i = is, ie - 2 do
            local u = column_indexes[i]
            sum = sum + values[i] * solved[u]
        end

        solved[y] = (augment_column_list[y] - sum) / values[ie - 1]
    end

    return M.with_vector(solved)
end

---Use upper triangular matrix to solve linear equations.
---@param upper_triangular_matrix CsrMatrix
---@param augment_column CsrMatrix
---@return CsrMatrix
function M.backward_substitution(upper_triangular_matrix, augment_column)
    local solved, augment_column_list = {}, M.to_list(augment_column)

    local values = upper_triangular_matrix.values
    local column_indexes = upper_triangular_matrix.column_indexes
    local row_ranges = upper_triangular_matrix.row_ranges
    local height = #row_ranges - 1

    for y = height, 1, -1 do
        local sum = 0
        local is, ie = row_ranges[y], row_ranges[y + 1]
        for i = ie - 1, is + 1, -1 do
            local u = column_indexes[i]
            sum = sum + values[i] * solved[u]
        end

        solved[y] = (augment_column_list[y] - sum) / values[is]
    end

    return M.with_vector(solved)
end

return M
