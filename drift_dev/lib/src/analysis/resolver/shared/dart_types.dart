import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_provider.dart';
import 'package:analyzer/dart/element/type_system.dart';
import 'package:drift/drift.dart' show DriftSqlType;

import '../../driver/error.dart';
import '../../results/results.dart';
import '../dart/helper.dart';
import '../resolver.dart';

class FoundDartClass {
  final InterfaceElement classElement;

  /// The instantiation of the [classElement], if the found type was a generic
  /// typedef.
  final List<DartType>? instantiation;

  FoundDartClass(this.classElement, this.instantiation);
}

ExistingRowClass? validateExistingClass(
  Iterable<DriftColumn> columns,
  FoundDartClass dartClass,
  String constructor,
  bool generateInsertable,
  LocalElementResolver step,
) {
  final desiredClass = dartClass.classElement;
  final library = desiredClass.library;
  var isAsyncFactory = false;

  ExecutableElement? ctor;
  final InterfaceType instantiation;

  if (dartClass.instantiation != null) {
    instantiation = desiredClass.instantiate(
      typeArguments: dartClass.instantiation!,
      nullabilitySuffix: NullabilitySuffix.none,
    );

    // If we have an instantation, search the constructor on the type because it
    // will report the right parameter types if they're generic.
    ctor = instantiation.lookUpConstructor(constructor, desiredClass.library);
  } else {
    ctor = desiredClass.getNamedConstructor(constructor);
    instantiation = library.typeSystem.instantiateInterfaceToBounds(
        element: desiredClass, nullabilitySuffix: NullabilitySuffix.none);
  }

  if (ctor == null) {
    final fallback = desiredClass.getMethod(constructor);

    if (fallback != null) {
      if (!fallback.isStatic) {
        step.reportError(DriftAnalysisError.forDartElement(
          fallback,
          'To use this method as a factory for the custom row class, it needs '
          'to be static.',
        ));
      }

      // The static factory must return a subtype of `FutureOr<ThatRowClass>`
      final expectedReturnType =
          library.typeProvider.futureOrType(instantiation);
      if (!library.typeSystem
          .isAssignableTo(fallback.returnType, expectedReturnType)) {
        step.reportError(DriftAnalysisError.forDartElement(
          fallback,
          'To be used as a factory for the custom row class, this method needs '
          'to return an instance of it.',
        ));
      }

      isAsyncFactory = library.typeSystem.flatten(fallback.returnType) !=
          fallback.returnType;

      ctor = fallback;
    }
  }

  if (ctor == null) {
    final msg = constructor == ''
        ? 'The desired data class must have an unnamed constructor'
        : 'The desired data class does not have a constructor named '
            '$constructor';

    step.reportError(DriftAnalysisError.forDartElement(desiredClass, msg));
    return null;
  }

  // Note: It's ok if not all columns are present in the custom row class, we
  // just won't load them in that case.message:
  // However, when we're supposed to generate an insertable, all columns must
  // appear as getters in the target class.
  final unmatchedColumnsByName = {
    for (final column in columns) column.nameInDart: column
  };

  final positionalColumns = <DriftColumn>[];
  final namedColumns = <ParameterElement, DriftColumn>{};

  for (final parameter in ctor.parameters) {
    final column = unmatchedColumnsByName.remove(parameter.name);
    if (column != null) {
      if (parameter.isPositional) {
        positionalColumns.add(column);
      } else {
        namedColumns[parameter] = column;
      }

      _checkParameterType(parameter, column, step);
    } else if (!parameter.isOptional) {
      step.reportError(DriftAnalysisError.forDartElement(
        parameter,
        'Unexpected parameter ${parameter.name} which has no matching column.',
      ));
    }
  }

  if (generateInsertable) {
    // Go through all columns, make sure that the class has getters for them.
    final missingGetters = <String>[];

    for (final column in columns) {
      final matchingField = dartClass.classElement
          .lookUpGetter(column.nameInDart, dartClass.classElement.library);

      if (matchingField == null) {
        missingGetters.add(column.nameInDart);
      }
    }

    if (missingGetters.isNotEmpty) {
      step.reportError(DriftAnalysisError.forDartElement(
        dartClass.classElement,
        'This class used as a custom row class for which an insertable '
        'is generated. This means that it must define getters for all '
        'columns, but some are missing: ${missingGetters.join(', ')}',
      ));
    }
  }

  return ExistingRowClass(
    targetClass: AnnotatedDartCode.topLevelElement(desiredClass),
    targetType: AnnotatedDartCode.build(
        (builder) => builder.addDartType(instantiation)),
    constructor: constructor,
    positionalColumns: [
      for (final column in positionalColumns) column.nameInSql
    ],
    namedColumns: {
      for (final named in namedColumns.entries)
        named.key.name: named.value.nameInSql,
    },
    generateInsertable: generateInsertable,
    isAsyncFactory: isAsyncFactory,
  );
}

AppliedTypeConverter? readTypeConverter(
  LibraryElement library,
  Expression dartExpression,
  DriftSqlType columnType,
  bool columnIsNullable,
  void Function(String) reportError,
  KnownDriftTypes helper,
) {
  final staticType = dartExpression.staticType;
  final asTypeConverter =
      staticType != null ? helper.asTypeConverter(staticType) : null;

  if (asTypeConverter == null) {
    reportError('Not a type converter');
    return null;
  }

  final dartType = asTypeConverter.typeArguments[0];
  final sqlType = asTypeConverter.typeArguments[1];

  final typeSystem = library.typeSystem;
  final dartTypeNullable = typeSystem.isNullable(dartType);
  final sqlTypeNullable = typeSystem.isNullable(sqlType);

  final asJsonConverter = helper.asJsonTypeConverter(staticType);
  final appliesToJsonToo = asJsonConverter != null;

  // Make the type converter support nulls by just mapping null to null if this
  // converter is otherwise non-nullable in both directions.
  final canBeSkippedForNulls = !dartTypeNullable && !sqlTypeNullable;

  if (sqlTypeNullable != columnIsNullable) {
    if (!columnIsNullable) {
      reportError('This column is non-nullable in the database, but has a '
          'type converter with a nullable SQL type, meaning that it may '
          "potentially map to `null` which can't be stored in the database.");
    } else if (!canBeSkippedForNulls) {
      final alternative = appliesToJsonToo
          ? 'JsonTypeConverter.asNullable'
          : 'NullAwareTypeConverter.wrap';

      reportError('This column is nullable, but the type converter has a non-'
          "nullable SQL type, meaning that it won't be able to map `null` "
          'from the database to Dart.\n'
          'Try wrapping the converter in `$alternative`');
    }
  }

  _checkType(columnType, columnIsNullable, null, sqlType, library.typeProvider,
      library.typeSystem, reportError);

  return AppliedTypeConverter(
    expression: AnnotatedDartCode.ast(dartExpression),
    dartType: dartType,
    jsonType: appliesToJsonToo ? asJsonConverter.typeArguments[2] : null,
    sqlType: columnType,
    dartTypeIsNullable: dartTypeNullable,
    sqlTypeIsNullable: sqlTypeNullable,
  );
}

AppliedTypeConverter readEnumConverter(
  void Function(String) reportError,
  DartType enumType,
) {
  if (enumType is! InterfaceType) {
    reportError('Not a class: `$enumType`');
  }

  final creatingClass = enumType.element;
  if (creatingClass is! EnumElement) {
    reportError('Not an enum: `${creatingClass!.displayName}`');
  }

  // `const EnumIndexConverter<EnumType>(EnumType.values)`
  final expression = AnnotatedDartCode.build((builder) {
    builder
      ..addText('const ')
      ..addSymbol('EnumIndexConverter', AnnotatedDartCode.drift)
      ..addText('<')
      ..addDartType(enumType)
      ..addText('>(')
      ..addDartType(enumType)
      ..addText('.values)');
  });

  return AppliedTypeConverter(
    expression: expression,
    dartType: enumType,
    jsonType: null,
    sqlType: DriftSqlType.int,
    dartTypeIsNullable: false,
    sqlTypeIsNullable: false,
  );
}

void _checkParameterType(ParameterElement element, DriftColumn column,
    LocalElementResolver resolver) {
  final type = element.type;
  final library = element.library!;
  final typesystem = library.typeSystem;

  void error(String message) {
    resolver.reportError(DriftAnalysisError.forDartElement(element, message));
  }

  final nullableDartType = column.nullableInDart;

  if (library.isNonNullableByDefault &&
      nullableDartType &&
      !typesystem.isNullable(type) &&
      element.isRequired) {
    error('Expected this parameter to be nullable');
    return;
  }

  _checkType(
    column.sqlType,
    column.nullable,
    column.typeConverter,
    element.type,
    library.typeProvider,
    library.typeSystem,
    error,
  );
}

void _checkType(
  DriftSqlType columnType,
  bool columnIsNullable,
  AppliedTypeConverter? typeConverter,
  DartType typeToCheck,
  TypeProvider typeProvider,
  TypeSystem typeSystem,
  void Function(String) error,
) {
  DartType expectedDartType;
  if (typeConverter != null) {
    expectedDartType = typeConverter.dartType;
    if (typeConverter.canBeSkippedForNulls && columnIsNullable) {
      typeToCheck = typeSystem.promoteToNonNull(typeToCheck);
    }
  } else {
    expectedDartType = typeProvider.typeFor(columnType);
  }

  // BLOB columns should be stored in an Uint8List (or a supertype of that).
  // We don't get a Uint8List from the type provider unfortunately, but as it
  // cannot be extended we can just check for that manually.
  final isAllowedUint8List = typeConverter == null &&
      columnType == DriftSqlType.blob &&
      typeToCheck is InterfaceType &&
      typeToCheck.element2.name == 'Uint8List' &&
      typeToCheck.element2.library.name == 'dart.typed_data';

  if (!typeSystem.isAssignableTo(expectedDartType, typeToCheck) &&
      !isAllowedUint8List) {
    error('Parameter must accept '
        '${expectedDartType.getDisplayString(withNullability: true)}');
  }
}

extension on TypeProvider {
  DartType typeFor(DriftSqlType type) {
    switch (type) {
      case DriftSqlType.int:
        return intType;
      case DriftSqlType.bigInt:
        return intElement.library.getClass('BigInt')!.instantiate(
            typeArguments: const [], nullabilitySuffix: NullabilitySuffix.none);
      case DriftSqlType.string:
        return stringType;
      case DriftSqlType.bool:
        return boolType;
      case DriftSqlType.dateTime:
        return intElement.library.getClass('DateTime')!.instantiate(
            typeArguments: const [], nullabilitySuffix: NullabilitySuffix.none);
      case DriftSqlType.blob:
        return listType(intType);
      case DriftSqlType.double:
        return doubleType;
    }
  }
}
