--[[
MariaDB sql: mysql's, plus `returning` on insert, replace, and delete.
]]

local dialect = require("db-query.sql.dialect")
local mysql = require("db-query.sql.dialect.mysql")

return dialect.derive(mysql, {
  name = "mariadb",
  reserved = dialect.set("returning"),
  -- Returning is written on insert, replace, and delete, and mariadb has no lateral.
  keywords = vim.tbl_extend("force", mysql.keywords, {
    from = vim.tbl_extend("force", dialect.without(mysql.keywords.from, "lateral"), dialect.set("returning")),
    where = vim.tbl_extend("force", mysql.keywords.where, dialect.set("returning")),
    delete_target = vim.tbl_extend("force", mysql.keywords.delete_target, dialect.set("returning")),
    values = vim.tbl_extend("force", mysql.keywords.values, dialect.set("returning")),
  }),
  clauses = {
    { word = "returning", clause = "returning" },
  },
})
