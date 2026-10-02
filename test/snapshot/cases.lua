--[[
Defines the test databases and the cases run against each of them.
]]

local M = {}

--- Each case is `{ name, text, extra }`, where `|` in `text` marks the cursor.
--- `extra` is the trigger character for a completion, and `includeDeclaration`
--- for a references request.
---@alias snapshot.Case [string, string, any]

---@class snapshot.Engine
---@field name string
---@field binary string
---@field schema string
---@field functions string[] Functions the schema creates. Completion snapshots leave out every other function, since those come with the installed version of the database.
---@field completions snapshot.Case[]
---@field hovers snapshot.Case[]
---@field signatures snapshot.Case[]
---@field definitions snapshot.Case[]

---@type snapshot.Engine[]
M.engines = {
  {
    name = "sqlite",
    binary = "sqlite3",
    schema = [[
create table customers (
  id integer primary key,
  name text not null,
  email text,
  created_at timestamp default current_timestamp,
  active boolean not null default 1
);
create table orders (
  id integer primary key,
  customer_id integer not null references customers(id),
  total numeric(10,2) not null,
  note varchar(200),
  placed date
);
create table audit (
  id integer primary key autoincrement,
  message text not null,
  total_cents integer generated always as (id * 100) virtual
);
create view big_orders as
  select o.id, o.total, c.name from orders o join customers c on c.id = o.customer_id where o.total > 100;
insert into customers (id, name, email, created_at) values (1, 'Ann', 'ann@x.com', '2024-01-01 00:00:00'), (2, 'Bob', null, '2024-01-02 00:00:00');
insert into orders (id, customer_id, total, note, placed) values (1, 1, 150.5, 'first', '2024-01-02'), (2, 2, 20, null, '2024-02-03');
]],
    functions = {},
    completions = {
      { "insert_audit_cols", "insert into audit (|" },
      { "insert_audit_statement", "insert into aud|" },
    },
    hovers = {},
    signatures = {
      { "sig_substr", "select substr('abc', |)" },
    },
    definitions = {},
  },
  {
    name = "duckdb",
    binary = "duckdb",
    schema = [[
create type mood as enum ('happy', 'sad', 'o''k');
create table customers (
  id integer primary key,
  name varchar not null,
  email varchar,
  mood mood not null,
  created_at timestamp default current_timestamp,
  tags varchar[],
  uid uuid
);
create table orders (
  id integer primary key,
  customer_id integer not null references customers(id),
  total decimal(10,2) not null,
  note varchar,
  placed date
);
create schema sales;
create table sales.regions (code varchar not null, label text, rank integer default 0);
create view big_orders as
  select o.id, o.total, c.name from orders o join customers c on c.id = o.customer_id where o.total > 100;
create macro add_tax(amount, rate := 0.1) as amount * (1 + rate);
create macro top_orders(n) as table select * from orders order by total desc limit n;
insert into customers (id, name, email, mood, created_at) values (1, 'Ann', 'ann@x.com', 'happy', '2024-01-01'), (2, 'Bob', null, 'sad', '2024-01-02');
insert into orders values (1, 1, 150.5, 'first', '2024-01-02'), (2, 2, 20, null, '2024-02-03');
]],
    functions = { "add_tax", "top_orders" },
    completions = {
      { "enum_literal", "select * from customers where mood = '|'" },
      { "enum_literal_trigger", "select * from customers where mood = '|'", "'" },
      { "enum_insert_literal", "insert into customers (id, name, mood) values (3, 'x', '|')" },
      { "schema_sales", "select * from sales.|" },
      { "sales_cols", "select r.| from sales.regions r" },
      { "macro_from", "select * from top_orders(1) t where t.|" },
      { "macro_arg", "select add_tax(|) from orders" },
      { "insert_customers_values", "insert into customers (id, name, email, mood, created_at, tags, uid) values (|)" },
      { "insert_customers_statement", "insert into cust|" },
      { "insert_sales", "insert into sales.|" },
    },
    hovers = {
      { "hover_macro", "select add_t|ax(1)" },
      { "hover_table_macro", "select * from top_ord|ers(1)" },
      { "hover_enum_col", "select mo|od from customers" },
      { "hover_schema_table", "select * from sales.reg|ions" },
    },
    signatures = {
      { "sig_macro", "select add_tax(1, |)" },
      { "sig_table_macro", "select * from top_orders(|)" },
    },
    definitions = {
      { "def_macro", "select add_t|ax(1)" },
      { "def_table_macro", "select * from top_or|ders(1)" },
      { "def_schema_table", "select * from sales.reg|ions" },
    },
  },
}

---@type snapshot.Case[]
M.completions = {
  { "kw_start", "|" },
  { "kw_partial", "sel|" },
  { "select_cols", "select | from customers" },
  { "select_partial_col", "select na| from customers" },
  { "qualified_alias", "select c.| from customers c" },
  { "qualified_table", "select customers.| from customers" },
  { "from_relations", "select * from |" },
  { "from_partial", "select * from ord|" },
  { "schema_main", "select * from main.|" },
  { "join_alias", "select o.id, c.| from orders o join customers c on c.id = o.customer_id" },
  { "join_on", "select * from orders o join customers c on c.id = o.|" },
  { "join_keyword", "select * from orders o |" },
  { "where_cols", "select * from orders where |" },
  { "where_after_value", "select * from orders where total > 5 |" },
  { "cte_cols", "with recent as (select id, total as amount from orders) select r.| from recent r" },
  { "cte_name", "with recent as (select id from orders) select * from |" },
  { "subquery_cols", "select s.| from (select id, name as who from customers) s" },
  { "view_cols", "select | from big_orders" },
  { "insert_target", "insert into |" },
  { "insert_cols_empty", "insert into orders (|" },
  { "insert_cols_empty_closed", "insert into orders (|)" },
  { "insert_cols_more", "insert into orders (customer_id, |" },
  { "insert_values", "insert into orders (customer_id, total, note) values (|)" },
  { "insert_values_two", "insert into orders (customer_id, total) values (|)" },
  { "insert_values_unknown", "insert into orders (customer_id, bogus) values (|)" },
  { "insert_values_second", "insert into orders (customer_id, total) values (1, |)" },
  { "update_set", "update orders set |" },
  { "delete_where", "delete from orders where |" },
  { "func_arg", "select coalesce(|) from customers" },
  { "order_by", "select * from orders order by total |" },
  { "group_by", "select customer_id, count(*) from orders group by |" },
  { "quoted_ident", 'select "|" from customers' },
  { "quoted_ident_trigger", 'select "|" from customers', '"' },
  { "string_open_trigger", "select * from customers where name = '|'", "'" },
  { "case_expr", "select case when total > 1 |" },
  { "multi_statement", "select 1;\nselect | from orders;" },
  { "exists_subquery", "select * from customers c where exists (select 1 from orders o where o.customer_id = c.|)" },
}

---@type snapshot.Case[]
M.hovers = {
  { "hover_column", "select tot|al from orders" },
  { "hover_table", "select * from ord|ers" },
  { "hover_view", "select * from big_|orders" },
  { "hover_alias_col", "select o.tot|al from orders o" },
  { "hover_alias", "select o|.total from orders o" },
  { "hover_function", "select coale|sce(1, 2)" },
  { "hover_keyword", "sel|ect 1" },
  { "hover_cte_col", "with r as (select id as rid from orders) select ri|d from r" },
}

---@type snapshot.Case[]
M.signatures = {
  { "sig_coalesce", "select coalesce(1, |)" },
  { "sig_extract", "select extract(|" },
  { "sig_cast", "select cast(|" },
  { "sig_none", "select |" },
}

---@type snapshot.Case[]
M.definitions = {
  { "def_table", "select * from ord|ers" },
  { "def_view", "select * from big_or|ders" },
  { "def_column", "select to|tal from orders" },
  { "def_alias_column", "select o.to|tal from orders o" },
}

---@type snapshot.Case[]
M.references = {
  { "refs_customers", "select * from custom|ers", true },
  { "refs_customers_nodecl", "select * from custom|ers", false },
  { "refs_orders", "select * from ord|ers", true },
  { "refs_view", "select * from big_or|ders", true },
}

---@class snapshot.Query
---@field name string
---@field sql string
---@field opts dbquery.ExecuteOptions
---@field row integer|nil 0-based cursor row, for a query run with `statement`.

local SELECT = "select id, name, email from customers order by id;"

--- Run in order against one buffer, so each query sees what the ones before
--- it wrote.
---@type snapshot.Query[]
M.queries = {
  { name = "01_text", sql = SELECT, opts = { format = "text" } },
  { name = "02_csv", sql = SELECT, opts = { format = "csv" } },
  {
    name = "03_multi",
    sql = "select count(*) as n from orders;\nselect id from customers order by id;",
    opts = { format = "text" },
  },
  {
    name = "04_insert",
    sql = "insert into orders (id, customer_id, total, note, placed) values (3, 1, 5, 'x', '2024-03-04');",
    opts = { format = "text" },
  },
  {
    name = "05_returning",
    sql = "insert into orders (id, customer_id, total) values (4, 2, 7) returning id, total;",
    opts = { format = "csv" },
  },
  { name = "06_ddl", sql = "create table extra (a integer);", opts = { format = "text" } },
  { name = "07_fail", sql = "select * from nosuch;", opts = { format = "text" } },
  {
    name = "08_statement",
    sql = "select 1 as one;\n\nselect 2 as two;",
    opts = { format = "csv", statement = true },
    row = 2,
  },
  { name = "09_double_semicolon", sql = "select id from orders order by id limit 2;;", opts = { format = "csv" } },
  {
    name = "10_comment_first",
    sql = "-- leading comment\nselect name from customers order by id;",
    opts = { format = "text" },
  },
  { name = "11_blank", sql = "\n\n", opts = { format = "text" } },
}

return M
