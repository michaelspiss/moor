import 'package:moor/moor.dart';

part 'custom_tables.g.dart';

@UseMoor(include: {'tables.moor'})
class CustomTablesDb extends _$CustomTablesDb {
  CustomTablesDb(QueryExecutor e) : super(e);

  @override
  int get schemaVersion => 1;
}
