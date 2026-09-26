--[[
MariaDB sql: mysql's, plus `returning` on insert, replace, and delete.
]]

local dialect = require("db-query.sql.dialect")
local mysql = require("db-query.sql.dialect.mysql")

local with = dialect.with

return dialect.derive(mysql, {
  name = "mariadb",
  reserved = dialect.set("returning"),
  keywords = {
    -- mariadb has no lateral.
    from = with(dialect.without(mysql.keywords.from, "lateral"), "returning"),
    where = with(mysql.keywords.where, "returning"),
    delete_target = with(mysql.keywords.delete_target, "returning"),
    values = with(mysql.keywords.values, "returning"),
  },
  clauses = {
    { word = "returning", clause = "returning" },
  },
})
