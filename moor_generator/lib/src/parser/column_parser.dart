import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:moor_generator/src/model/used_type_converter.dart';
import 'package:moor_generator/src/state/errors.dart';
import 'package:moor_generator/src/model/specified_column.dart';
import 'package:moor_generator/src/parser/parser.dart';
import 'package:moor_generator/src/state/session.dart';
import 'package:moor_generator/src/utils/type_utils.dart';
import 'package:recase/recase.dart';

const String startInt = 'integer';
const String startString = 'text';
const String startBool = 'boolean';
const String startDateTime = 'dateTime';
const String startBlob = 'blob';
const String startReal = 'real';

final Set<String> starters = {
  startInt,
  startString,
  startBool,
  startDateTime,
  startBlob,
  startReal,
};

const String _methodNamed = 'named';
const String _methodReferences = 'references';
const String _methodAutoIncrement = 'autoIncrement';
const String _methodWithLength = 'withLength';
const String _methodNullable = 'nullable';
const String _methodCustomConstraint = 'customConstraint';
const String _methodDefault = 'withDefault';
const String _methodMap = 'map';

const String _errorMessage = 'This getter does not create a valid column that '
    'can be parsed by moor. Please refer to the readme from moor to see how '
    'columns are formed. If you have any questions, feel free to raise an issue.';

class ColumnParser extends ParserBase {
  ColumnParser(GeneratorSession session) : super(session);

  SpecifiedColumn parse(MethodDeclaration getter, Element getterElement) {
    /*
      These getters look like this: ... get id => integer().autoIncrement()();
      The last () is a FunctionExpressionInvocation, the entries before that
      (here autoIncrement and integer) are MethodInvocations.
      We go through each of the method invocations until we hit one that starts
      the chain (integer, text, boolean, etc.). From each method in the chain,
      we can extract what it means for the column (name, auto increment, PK,
      constraints...).
     */

    final expr = returnExpressionOfMethod(getter);

    if (!(expr is FunctionExpressionInvocation)) {
      session.errors.add(MoorError(
        affectedElement: getter.declaredElement,
        message: _errorMessage,
        critical: true,
      ));

      return null;
    }

    var remainingExpr =
        (expr as FunctionExpressionInvocation).function as MethodInvocation;

    String foundStartMethod;
    String foundExplicitName;
    String foundCustomConstraint;
    Expression foundDefaultExpression;
    Expression createdTypeConverter;
    DartType typeConverterRuntime;
    var nullable = false;

    final foundFeatures = <ColumnFeature>[];

    while (true) {
      final methodName = remainingExpr.methodName.name;

      if (starters.contains(methodName)) {
        foundStartMethod = methodName;
        break;
      }

      switch (methodName) {
        case _methodNamed:
          if (foundExplicitName != null) {
            session.errors.add(
              MoorError(
                critical: false,
                affectedElement: getter.declaredElement,
                message:
                    "You're setting more than one name here, the first will "
                    'be used',
              ),
            );
          }

          foundExplicitName =
              readStringLiteral(remainingExpr.argumentList.arguments.first, () {
            session.errors.add(
              MoorError(
                critical: false,
                affectedElement: getter.declaredElement,
                message:
                    'This table name is cannot be resolved! Please only use '
                    'a constant string as parameter for .named().',
              ),
            );
          });
          break;
        case _methodReferences:
          break;
        case _methodWithLength:
          final args = remainingExpr.argumentList;
          final minArg = findNamedArgument(args, 'min');
          final maxArg = findNamedArgument(args, 'max');

          foundFeatures.add(LimitingTextLength.withLength(
            min: readIntLiteral(minArg, () {}),
            max: readIntLiteral(maxArg, () {}),
          ));
          break;
        case _methodAutoIncrement:
          foundFeatures.add(AutoIncrement());
          // a column declared as auto increment is always a primary key
          foundFeatures.add(const PrimaryKey());
          break;
        case _methodNullable:
          nullable = true;
          break;
        case _methodCustomConstraint:
          foundCustomConstraint =
              readStringLiteral(remainingExpr.argumentList.arguments.first, () {
            session.errors.add(
              MoorError(
                critical: false,
                affectedElement: getter.declaredElement,
                message:
                    'This constraint is cannot be resolved! Please only use '
                    'a constant string as parameter for .customConstraint().',
              ),
            );
          });
          break;
        case _methodDefault:
          final args = remainingExpr.argumentList;
          final expression = args.arguments.single;
          foundDefaultExpression = expression;
          break;
        case _methodMap:
          final args = remainingExpr.argumentList;
          final expression = args.arguments.single;

          // the map method has a parameter type that resolved to the runtime
          // type of the custom object
          final type = remainingExpr.typeArgumentTypes.single;

          createdTypeConverter = expression;
          typeConverterRuntime = type;
          break;
      }

      // We're not at a starting method yet, so we need to go deeper!
      final inner = (remainingExpr.target) as MethodInvocation;
      remainingExpr = inner;
    }

    ColumnName name;
    if (foundExplicitName != null) {
      name = ColumnName.explicitly(foundExplicitName);
    } else {
      name = ColumnName.implicitly(ReCase(getter.name.name).snakeCase);
    }

    final columnType = _startMethodToColumnType(foundStartMethod);

    UsedTypeConverter converter;
    if (createdTypeConverter != null && typeConverterRuntime != null) {
      converter = UsedTypeConverter(
          expression: createdTypeConverter,
          mappedType: typeConverterRuntime,
          sqlType: columnType);
    }

    return SpecifiedColumn(
        type: columnType,
        dartGetterName: getter.name.name,
        name: name,
        overriddenJsonName: _readJsonKey(getterElement),
        customConstraints: foundCustomConstraint,
        nullable: nullable,
        features: foundFeatures,
        defaultArgument: foundDefaultExpression?.toSource(),
        typeConverter: converter);
  }

  ColumnType _startMethodToColumnType(String startMethod) {
    return const {
      startBool: ColumnType.boolean,
      startString: ColumnType.text,
      startInt: ColumnType.integer,
      startDateTime: ColumnType.datetime,
      startBlob: ColumnType.blob,
      startReal: ColumnType.real,
    }[startMethod];
  }

  String _readJsonKey(Element getter) {
    final annotations = getter.metadata;
    final object = annotations.singleWhere((e) {
      final value = e.computeConstantValue();
      return isFromMoor(value.type) && value.type.name == 'JsonKey';
    }, orElse: () => null);

    if (object == null) return null;

    return object.constantValue.getField('key').toStringValue();
  }
}
