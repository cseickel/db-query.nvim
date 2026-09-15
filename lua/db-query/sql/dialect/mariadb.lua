--[[
MariaDB sql: mysql's, plus `returning` on insert, replace, and delete.
]]

local dialect = require("db-query.sql.dialect")
local mysql = require("db-query.sql.dialect.mysql")

return dialect.derive(mysql, {
  name = "mariadb",
  reserved = dialect.set("returning"),
  clauses = {
    { word = "returning", clause = "returning" },
  },
})
