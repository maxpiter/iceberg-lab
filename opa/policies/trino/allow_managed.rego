# Дополнение стенда к официальным политикам Lakekeeper (v0.13.6), не часть оригинала.
# Официальный allow_table.rego разрешает только процедуры обслуживания
# (optimize, expire_snapshots и др.), откат к снимку в списке нет.
# Здесь rollback_to_snapshot разрешается с тем же условием, что и обслуживание:
# у пользователя должно быть право на запись в таблицу (modify в Lakekeeper).
package trino

allow_managed if {
	input.action.operation == "ExecuteTableProcedure"
	input.action.resource.function.functionName == "ROLLBACK_TO_SNAPSHOT"
	table := input.action.resource.table.tableName
	is_metadata_table(table) == false
	catalog := input.action.resource.table.catalogName
	schema := input.action.resource.table.schemaName
	require_table_access_simple(catalog, schema, table, "write_data")
}
