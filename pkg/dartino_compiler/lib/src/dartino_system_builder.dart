// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library dartino_compiler.dartino_system_builder;

import 'dart:typed_data';

import 'package:compiler/src/constants/values.dart' show
    ConstantValue,
    ConstructedConstantValue,
    DeferredConstantValue,
    FunctionConstantValue,
    IntConstantValue,
    MapConstantValue;

import 'package:compiler/src/elements/elements.dart' show
    ClassElement,
    ConstructorElement,
    Element,
    FieldElement,
    FunctionElement,
    FunctionSignature,
    FunctionTypedElement,
    LibraryElement,
    LocalElement,
    MemberElement,
    Name,
    ParameterElement;

import 'package:compiler/src/common/names.dart' show
    Identifiers;

import 'package:compiler/src/universe/selector.dart' show
    Selector;

import 'package:compiler/src/common/names.dart' show
    Names;

import 'package:persistent/persistent.dart' show
    PersistentMap,
    PersistentSet;

import 'dartino_constants.dart' show
    DartinoClassInstanceConstant;

import '../dartino_class_base.dart' show
    DartinoClassBase;

import '../dartino_class.dart' show
    DartinoClass;

import 'closure_environment.dart' show
    ClosureInfo;

import '../dartino_field.dart' show
    DartinoField;

import 'dartino_system_base.dart' show
    DartinoSystemBase;

import 'dartino_selector.dart' show
    DartinoSelector;

import 'dartino_diagnostic_reporter.dart' show
    DartinoDiagnosticReporter;

import 'dartino_class_builder.dart';
import 'dartino_function_builder.dart';

import '../dartino_system.dart';
import '../vm_commands.dart';

class DartinoSystemBuilder extends DartinoSystemBase {
  final DartinoSystem predecessorSystem;
  final int functionIdStart;
  final int classIdStart;

  final List<DartinoFunctionBuilder> _newFunctions = <DartinoFunctionBuilder>[];
  final Map<int, DartinoClassBuilder> _newClasses =
      <int, DartinoClassBuilder>{};
  final Map<ConstantValue, int> _newConstants = <ConstantValue, int>{};
  final Map<ParameterStubSignature, DartinoFunctionBuilder> _newParameterStubs =
      <ParameterStubSignature, DartinoFunctionBuilder>{};

  final Map<int, int> _newGettersByFieldIndex = <int, int>{};
  final Map<int, int> _newSettersByFieldIndex = <int, int>{};

  final Set<DartinoFunction> _removedFunctions = new Set<DartinoFunction>();

  final Map<Element, DartinoFunctionBuilder> _functionBuildersByElement =
      <Element, DartinoFunctionBuilder>{};

  final Map<ClassElement, DartinoClassBuilder> _classBuildersByElement =
      <ClassElement, DartinoClassBuilder>{};

  final Map<ConstructorElement, DartinoFunctionBuilder>
      _newConstructorInitializers =
          <ConstructorElement, DartinoFunctionBuilder>{};

  final Map<int, List<int>> _replaceUsage = <int, List<int>>{};

  final Map<FieldElement, int> _newLazyInitializersByElement =
      <FieldElement, int>{};

  final Map<int, int> _newTearoffsById = <int, int>{};

  final Map<int, int> _newTearoffGettersById = <int, int>{};

  final int maxInt64 = (1 << 63) - 1;
  final int minInt64 = -(1 << 63);

  final Map<int, String> _symbolByDartinoSelectorId = <int, String>{};

  final Map<int, Set<DartinoFunctionBase>> _newParameterStubsById =
      <int, Set<DartinoFunctionBase>>{};

  // TODO(ahe): This should be queried from World.
  final Map<ClassElement, Set<ClassElement>> directSubclasses =
      <ClassElement, Set<ClassElement>>{};

  /// Set of classes that have special meaning to the Dartino VM. They're
  /// created using [PushBuiltinClass] instead of [PushNewClass].
  final Set<ClassElement> builtinClasses = new Set<ClassElement>();

  final Set<String> _names = new Set<String>();

  final Map<LibraryElement, String> _libraryTag = <LibraryElement, String>{};

  final List<String> _symbols = <String>[];

  final Map<String, int> _symbolIds = <String, int>{};

  final Map<Selector, String> _selectorToSymbol = <Selector, String>{};

  final Map<FieldElement, int> _newStaticFieldsById = <FieldElement, int>{};

  DartinoSystemBuilder(DartinoSystem predecessorSystem)
      : this.predecessorSystem = predecessorSystem,
        this.functionIdStart = predecessorSystem.computeMaxFunctionId() + 1,
        this.classIdStart = predecessorSystem.computeMaxClassId() + 1;

  int lookupConstantIdByValue(ConstantValue value) {
    int id = _newConstants[value];
    if (id != null) return id;
    DartinoConstant constant = predecessorSystem.lookupConstantByValue(value);
    return constant?.id;
  }

  void replaceUsage(int user, int used) {
    _replaceUsage.putIfAbsent(user, () => <int>[]).add(used);
  }

  void replaceElementUsage(Element user, Element used) {
    DartinoFunction userFunction =
        predecessorSystem.lookupFunctionByElement(user);
    if (userFunction == null) return;
    DartinoFunction usedFunction =
        predecessorSystem.lookupFunctionByElement(used);
    if (usedFunction == null) return;
    replaceUsage(userFunction.functionId, usedFunction.functionId);
  }

  DartinoFunctionBuilder newFunctionBuilder(
      DartinoFunctionKind kind,
      int arity,
      {String name,
       Element element,
       FunctionSignature signature,
       int memberOf: -1,
       Element mapByElement}) {
    int nextFunctionId = functionIdStart + _newFunctions.length;
    DartinoFunctionBuilder builder = new DartinoFunctionBuilder(
        nextFunctionId,
        kind,
        arity,
        name: name,
        element: element,
        signature: signature,
        memberOf: memberOf);
    _newFunctions.add(builder);
    if (mapByElement != null) {
      _functionBuildersByElement[mapByElement] = builder;
    }
    return builder;
  }

  DartinoFunctionBuilder newFunctionBuilderWithSignature(
      String name,
      Element element,
      FunctionSignature signature,
      int memberOf,
      {DartinoFunctionKind kind: DartinoFunctionKind.NORMAL,
       Element mapByElement}) {
    int arity = signature.parameterCount + (memberOf >= 0 ? 1 : 0);
    return newFunctionBuilder(
          kind,
          arity,
          name: name,
          element: element,
          signature: signature,
          memberOf: memberOf,
          mapByElement: mapByElement);
  }

  DartinoFunctionBase lookupFunction(int functionId) {
    if (functionId < functionIdStart) {
      return predecessorSystem.lookupFunctionById(functionId);
    } else {
      return lookupFunctionBuilder(functionId);
    }
  }

  DartinoFunctionBuilder lookupFunctionBuilder(int functionId) {
    return _newFunctions[functionId - functionIdStart];
  }

  DartinoFunctionBase lookupFunctionByElement(Element element) {
    DartinoFunctionBase function = _functionBuildersByElement[element];
    if (function != null) return function;
    return predecessorSystem.lookupFunctionByElement(element);
  }

  DartinoFunctionBuilder lookupFunctionBuilderByElement(Element element) {
    return _functionBuildersByElement[element];
  }

  int lookupLazyFieldInitializerByElement(FieldElement field) {
    int functionId = _newLazyInitializersByElement[field];
    if (functionId != null) return functionId;
    return predecessorSystem.lookupLazyFieldInitializerByElement(field);
  }

  DartinoFunctionBuilder newLazyFieldInitializer(FieldElement field) {
    // TODO(zarah): use unique name (which includes library and class)
    DartinoFunctionBuilder builder = newFunctionBuilder(
        DartinoFunctionKind.LAZY_FIELD_INITIALIZER,
        0,
        name: "${field.name} lazy initializer",
        element: field
    );
    _newLazyInitializersByElement[field] = builder.functionId;
    return builder;
  }

  DartinoFunctionBase lookupConstructorInitializerByElement(
      ConstructorElement element) {
    assert(element.isImplementation);
    DartinoFunctionBase function = _newConstructorInitializers[element];
    if (function != null) return function;
    return predecessorSystem.lookupConstructorInitializerByElement(element);
  }

  DartinoFunctionBuilder newConstructorInitializer(ConstructorElement element) {
    assert(element.isImplementation);
    DartinoFunctionBuilder builder = newFunctionBuilderWithSignature(
        element.name,
        element,
        element.functionSignature,
        -1,
        kind: DartinoFunctionKind.INITIALIZER_LIST);
    _newConstructorInitializers[element] = builder;
    return builder;
  }

  int lookupTearOffById(int functionId) {
    int id = _newTearoffsById[functionId];
    if (id != null) return id;
    return predecessorSystem.lookupTearOffById(functionId);
  }

  DartinoFunctionBuilder newTearOff(DartinoFunctionBase function, int classId) {
    assert(_newTearoffsById[function.functionId] == null);
    DartinoFunctionBuilder builder = newFunctionBuilderWithSignature(
        'call',
        null,
        function.signature,
        classId);
    _newTearoffsById[function.functionId] = builder.functionId;
    return builder;
  }

  int lookupTearOffGetterById(int functionId) {
    int id = _newTearoffGettersById[functionId];
    if (id != null) return id;
    return predecessorSystem.lookupTearOffGetterById(functionId);
  }

  DartinoFunctionBuilder newTearOffGetter(DartinoFunctionBase function) {
    assert(_newTearoffGettersById[function.functionId] == null);
    DartinoFunctionBuilder getter = newFunctionBuilder(
        DartinoFunctionKind.ACCESSOR,
        1);
    _newTearoffGettersById[function.functionId] = getter.functionId;
    return getter;
  }

  /// Return a getter for [fieldIndex] if it already exists, return null
  /// otherwise.
  int lookupGetterByFieldIndex(int fieldIndex) {
    int functionId = _newGettersByFieldIndex[fieldIndex];
    if (functionId == null) {
      return predecessorSystem.lookupGetterByFieldIndex(fieldIndex);
    }
    return functionId;
  }

  /// Create a new getter for [fieldIndex].
  DartinoFunctionBuilder newGetter(int fieldIndex) {
    DartinoFunctionBuilder builder =
        newFunctionBuilder(DartinoFunctionKind.ACCESSOR, 1);
    _newGettersByFieldIndex[fieldIndex] = builder.functionId;
    return builder;
  }

  /// Return a getter for [fieldIndex]. If one doesn't already exists, one will
  /// be created.
  int getGetterByFieldIndex(int fieldIndex) {
    int id = lookupGetterByFieldIndex(fieldIndex);
    if (id != null) return id;
    DartinoFunctionBuilder stub = newGetter(fieldIndex);
    stub.assembler
        ..loadParameter(0)
        ..loadField(fieldIndex)
        ..ret()
        ..methodEnd();
    return stub.functionId;
  }

  /// Return a setter for [fieldIndex] if it already exists, return null
  /// otherwise.
  int lookupSetterByFieldIndex(int fieldIndex) {
    int functionId = _newSettersByFieldIndex[fieldIndex];
    if (functionId == null) {
      return predecessorSystem.lookupSetterByFieldIndex(fieldIndex);
    }
    return functionId;
  }

  /// Create a new setter for [fieldIndex].
  DartinoFunctionBuilder newSetter(int fieldIndex) {
    DartinoFunctionBuilder builder =
        newFunctionBuilder(DartinoFunctionKind.ACCESSOR, 2);
    _newSettersByFieldIndex[fieldIndex] = builder.functionId;
    return builder;
  }

  /// Return a setter for [fieldIndex]. If one doesn't already exists, one will
  /// be created.
  int getSetterByFieldIndex(int fieldIndex) {
    int id = lookupSetterByFieldIndex(fieldIndex);
    if (id != null) return id;
    DartinoFunctionBuilder stub = newSetter(fieldIndex);
    stub.assembler
        ..loadParameter(0)
        ..loadParameter(1)
        ..storeField(fieldIndex)
        // Top is at this point the rhs argument, thus the return value.
        ..ret()
        ..methodEnd();
    return stub.functionId;
  }

  void forgetFunction(DartinoFunction function) {
    _removedFunctions.add(function);
  }

  List<DartinoFunctionBuilder> getNewFunctions() => _newFunctions;

  DartinoClassBase lookupTearoffClass(DartinoFunctionBase function) {
    int functionId = lookupTearOffById(function.functionId);
    if (functionId == null) return null;
    DartinoFunctionBase functionBuilder = lookupFunction(functionId);
    return lookupClassById(functionBuilder.memberOf);
  }

  DartinoClassBuilder getClassBuilder(
      ClassElement element,
      {Map<ClassElement, SchemaChange> schemaChanges}) {
    if (element == null) return null;
    assert(element.isDeclaration);

    DartinoClassBuilder classBuilder = lookupClassBuilderByElement(element);
    if (classBuilder != null) return classBuilder;

    directSubclasses[element] = new Set<ClassElement>();
    DartinoClassBuilder superclass =
    getClassBuilder(element.superclass, schemaChanges: schemaChanges);
    if (superclass != null) {
      Set<ClassElement> subclasses = directSubclasses[element.superclass];
      subclasses.add(element);
    }
    SchemaChange schemaChange;
    if (schemaChanges != null) {
      schemaChange = schemaChanges[element];
    }
    if (schemaChange == null) {
      schemaChange = new SchemaChange(element);
    }
    classBuilder = newClassBuilder(
        element, superclass, builtinClasses.contains(element), schemaChange);

    // TODO(ajohnsen): Currently, the DartinoRegistry does not enqueue fields.
    // This is a workaround, where we basically add getters for all fields.
    classBuilder.updateImplicitAccessors();

    return classBuilder;
  }

  DartinoClassBuilder newClassBuilderInternal(
      DartinoClass klass,
      DartinoClassBase superclass,
      SchemaChange schemaChange) {
    DartinoClassBuilder builder =
        new DartinoClassBuilder.patch(klass, superclass, schemaChange, this);
    assert(_newClasses[klass.classId] == null);
    _newClasses[klass.classId] = builder;
    return builder;
  }

  DartinoClassBuilder newPatchClassBuilderFromBase(
      DartinoClassBase base,
      SchemaChange schemaChange) {
    DartinoClass klass = predecessorSystem.lookupClassById(base.classId);
    DartinoClass superclass =
        predecessorSystem.lookupClassById(base.superclassId);
    return newClassBuilderInternal(klass, superclass, schemaChange);
  }

  DartinoClassBuilder newPatchClassBuilder(
      int classId,
      DartinoClassBase superclass,
      SchemaChange schemaChange) {
    DartinoClass klass = predecessorSystem.lookupClassById(classId);
    return newClassBuilderInternal(klass, superclass, schemaChange);
  }

  DartinoClassBuilder newClassBuilder(
      ClassElement element,
      DartinoClassBase superclass,
      bool isBuiltin,
      SchemaChange schemaChange,
      {List<DartinoField> extraFields: const <DartinoField>[]}) {
    if (element != null) {
      DartinoClass klass = predecessorSystem.lookupClassByElement(element);
      if (klass != null) {
        DartinoClassBuilder builder =
            newClassBuilderInternal(klass, superclass, schemaChange);
        _classBuildersByElement[element] = builder;
        return builder;
      }
    }

    int nextClassId = classIdStart + _newClasses.length;
    DartinoClassBuilder builder = new DartinoClassBuilder.newClass(
        nextClassId,
        element,
        superclass,
        isBuiltin,
        extraFields,
        this);
    _newClasses[nextClassId] = builder;
    if (element != null) _classBuildersByElement[element] = builder;
    return builder;
  }

  DartinoClassBase lookupClassById(int classId) {
    DartinoClassBase builder = lookupClassBuilder(classId);
    if (builder != null) return builder;
    return predecessorSystem.lookupClassById(classId);
  }

  DartinoClassBuilder lookupClassBuilder(int classId) {
    return _newClasses[classId];
  }

  DartinoClassBase lookupClassByElement(ClassElement element) {
    DartinoClassBase builder = lookupClassBuilderByElement(element);
    if (builder != null) return builder;
    return predecessorSystem.lookupClassByElement(element);
  }

  DartinoClassBuilder lookupClassBuilderByElement(ClassElement element) {
    return _classBuildersByElement[element];
  }

  Iterable<DartinoClassBuilder> getNewClasses() => _newClasses.values;

  bool registerConstant(ConstantValue constant) {
    if (predecessorSystem.lookupConstantByValue(constant) != null) return false;
    bool isNew = false;
    _newConstants.putIfAbsent(constant, () {
      isNew = true;
      // TODO(zarah): Compute max constant id (as for functions an classes)
      // instead of using constantsById.length
      return predecessorSystem.constantsById.length + _newConstants.length;
    });
    return isNew;
  }

  void registerBuiltinClass(ClassElement cls) {
    builtinClasses.add(cls);
  }

  void registerSymbol(String symbol, int dartinoSelectorId) {
    _symbolByDartinoSelectorId[dartinoSelectorId] = symbol;
  }

  DartinoFunctionBase lookupParameterStub(ParameterStubSignature signature) {
    DartinoFunctionBuilder stub = _newParameterStubs[signature];
    if (stub != null) return stub;
    return predecessorSystem.lookupParameterStub(signature);
  }


  PersistentSet<DartinoFunctionBase> lookupParameterStubsForFunction(int id) {
    Set<DartinoFunctionBase> stubs = _newParameterStubsById[id];
    if (stubs != null) return new PersistentSet.from(stubs);
    return predecessorSystem.lookupParameterStubsForFunction(id);
  }

  void registerParameterStub(
      DartinoFunctionBase base,
      ParameterStubSignature signature,
      DartinoFunctionBuilder stub) {
    assert(lookupParameterStub(signature) == null);
    _newParameterStubs[signature] = stub;
    _newParameterStubsById.
        putIfAbsent(base.functionId, () => new Set<DartinoFunctionBase>())
            .add(stub);
  }

  DartinoFunctionBuilder getClosureFunctionBuilder(
      FunctionElement function,
      ClassElement functionClass,
      ClosureInfo info,
      DartinoClassBase superclass) {
    DartinoFunctionBuilder closure = lookupFunctionBuilderByElement(function);
    if (closure != null) return closure;

    List<DartinoField> fields = <DartinoField>[];
    for (LocalElement local in info.free) {
      fields.add(new DartinoField.boxed(local));
    }
    if (info.isThisFree) {
      fields.add(
          new DartinoField.boxedThis(
              function.declaration.enclosingClass.declaration));
    }

    DartinoClassBuilder classBuilder = newClassBuilder(
        null, superclass, false, new SchemaChange(null), extraFields: fields);
    classBuilder.createIsFunctionEntry(
        functionClass, function.functionSignature.parameterCount);

    FunctionTypedElement implementation = function.implementation;

    return newFunctionBuilderWithSignature(
        Identifiers.call,
        function,
        // Parameter initializers are expressed in the potential
        // implementation.
        implementation.functionSignature,
        classBuilder.classId,
        kind: DartinoFunctionKind.NORMAL,
        mapByElement: function.declaration);
  }

  void setNames(Map<String, String> names) {
    // Generate symbols of the values.
    for (String name in names.values) {
      this._names.add(name);
      getSymbolId(name);
    }
  }

  String mangleName(Name name) {
    if (!name.isPrivate) return name.text;
    if (name.library.isPlatformLibrary && _names.contains(name.text)) {
      return name.text;
    }
    return name.text + getLibraryTag(name.library);
  }

  String getLibraryTag(LibraryElement library) {
    String tag = predecessorSystem.getLibraryTag(library);
    if (tag != null) return tag;
    return _libraryTag.putIfAbsent(library, () {
      // Give the core library the unique mangling of the empty string. That
      // will make the VM able to create selector into core (used for e.g.
      // _noSuchMethodTrampoline).
      if (library.isDartCore) return "";
      return "%${_libraryTag.length}";
    });
  }

  int getStaticFieldIndex(FieldElement element, Element referrer) {
    int id = predecessorSystem.getStaticFieldIndex(element, referrer);
    if (id != -1) return id;
    return _newStaticFieldsById.putIfAbsent(element, () {
        return predecessorSystem.staticFieldsById.length +
            _newStaticFieldsById.length;
    });
  }

  String getSymbolFromSelector(Selector selector) {
    String symbol = predecessorSystem.getSymbolFromSelector(selector);
    if (symbol != null) return symbol;
    return _selectorToSymbol.putIfAbsent(selector, () {
      StringBuffer buffer = new StringBuffer();
      buffer.write(mangleName(selector.memberName));
      for (String namedArgument in selector.namedArguments) {
        buffer.write(":");
        buffer.write(namedArgument);
      }
      return buffer.toString();
    });
  }

  void writeNamedArguments(StringBuffer buffer, FunctionSignature signature) {
    signature.orderedForEachParameter((ParameterElement parameter) {
      if (parameter.isNamed) {
        buffer.write(":");
        buffer.write(parameter.name);
      }
    });
  }

  String getSymbolForFunction(
      Name name,
      FunctionSignature signature) {
    StringBuffer buffer = new StringBuffer();
    buffer.write(mangleName(name));
    writeNamedArguments(buffer, signature);
    return buffer.toString();
  }

  String getCallSymbol(FunctionSignature signature) {
    return getSymbolForFunction(Names.call, signature);
  }

  int getSymbolId(String symbol) {
    int id = predecessorSystem.getSymbolId(symbol);
    if (id != -1) return id;
    return _symbolIds.putIfAbsent(symbol, () {
      int id = _symbols.length + predecessorSystem.symbols.length;
      assert(id == _symbolIds.length + predecessorSystem.symbolIds.length);
      _symbols.add(symbol);
      registerSymbol(symbol, id);
      return id;
    });
  }

  void forEachStatic(f(FieldElement element, int index)) {
    staticIndices.forEach(f);
  }

  int toDartinoTearoffIsSelector(
      String functionName,
      ClassElement classElement) {
    LibraryElement library = classElement.library;
    StringBuffer buffer = new StringBuffer();
    buffer.write("?is?");
    buffer.write(functionName);
    buffer.write("?");
    buffer.write(classElement.name);
    buffer.write("?");
    buffer.write(getLibraryTag(library));
    int id = getSymbolId(buffer.toString());
    return DartinoSelector.encodeMethod(id, 0);
  }

  String lookupSymbolById(int id) {
    return predecessorSystem.lookupSymbolById(id) ?? _symbols[id];
  }

  // TODO(ahe): Remove this when we support adding static fields.
  bool get hasNewStaticFields => _newStaticFieldsById.isNotEmpty;

  DartinoSystem computeSystem(
      DartinoDiagnosticReporter reporter,
      List<VmCommand> commands,
      bool compilationFailed,
      bool isBigintEnabled,
      ClassElement bigintClass,
      ClassElement uint32DigitsClass) {
    int changes = 0;

    commands.add(const PrepareForChanges());

    // Remove all removed DartinoFunctions.
    for (DartinoFunction function in _removedFunctions) {
      commands.add(new RemoveFromMap(MapId.methods, function.functionId));
    }

    // Create all new DartinoFunctions.
    List<DartinoFunction> functions = <DartinoFunction>[];
    for (DartinoFunctionBuilder builder in _newFunctions) {
      reporter.withCurrentElement(builder.element, () {
        functions.add(builder.finalizeFunction(this, commands));
      });
    }

    // Create all new DartinoClasses.
    List<DartinoClass> classes = <DartinoClass>[];
    for (DartinoClassBuilder builder in _newClasses.values) {
      classes.add(builder.finalizeClass(commands));
      changes++;
    }

    // Create all statics.
    // TODO(ajohnsen): Should be part of the dartino system. Does not work with
    // incremental.
    if (predecessorSystem.isEmpty) {
      _newStaticFieldsById.forEach((FieldElement element, int index) {
        int functionId = lookupLazyFieldInitializerByElement(element);
        if (functionId != null) {
          commands.add(new PushFromMap(MapId.methods, functionId));
          commands.add(const PushNewInitializer());
        } else {
          commands.add(const PushNull());
        }
      });
      commands.add(new ChangeStatics(_newStaticFieldsById.length));
      changes++;
    }

    // Create all DartinoConstants.
    PersistentMap<int, DartinoConstant> constantsById =
        predecessorSystem.constantsById;
    PersistentMap<ConstantValue, DartinoConstant> constantsByValue =
        predecessorSystem.constantsByValue;
    _newConstants.forEach((constant, int id) {
      void addList(List<ConstantValue> list, bool isByteList) {
        for (ConstantValue entry in list) {
          int entryId = lookupConstantIdByValue(entry);
          commands.add(new PushFromMap(MapId.constants, entryId));
          if (entry.isInt) {
            IntConstantValue constant = entry;
            int value = constant.primitiveValue;
            if (value & 0xFF == value) continue;
          }
          isByteList = false;
        }
        if (isByteList) {
          // TODO(ajohnsen): The PushConstantByteList command could take a
          // paylod with the data content.
          commands.add(new PushConstantByteList(list.length));
        } else {
          commands.add(new PushConstantList(list.length));
        }
      }

      while (constant is DeferredConstantValue) {
        assert(compilationFailed);
        // TODO(ahe): This isn't correct, and only serves to prevent the
        // compiler from crashing. However, the compiler does print a lot of
        // errors about not supporting deferred loading, so it should be fine.
        constant = constant.referenced;
      }

      if (constant.isInt) {
        var value = constant.primitiveValue;
        if (value > maxInt64 || value < minInt64) {
          assert(isBigintEnabled);
          bool negative = value < 0;
          value = negative ? -value : value;
          var parts = new List();
          while (value != 0) {
            parts.add(value & 0xffffffff);
            value >>= 32;
          }

          commands.add(new PushNewBigInteger(
              negative,
              parts,
              MapId.classes,
              lookupClassByElement(bigintClass).classId,
              lookupClassByElement(uint32DigitsClass).classId));
        } else {
          commands.add(new PushNewInteger(constant.primitiveValue));
        }
      } else if (constant.isDouble) {
        commands.add(new PushNewDouble(constant.primitiveValue));
      } else if (constant.isTrue) {
        commands.add(new PushBoolean(true));
      } else if (constant.isFalse) {
        commands.add(new PushBoolean(false));
      } else if (constant.isNull) {
        commands.add(const PushNull());
      } else if (constant.isString) {
        Iterable<int> list = constant.primitiveValue.slowToString().codeUnits;
        if (list.any((codeUnit) => codeUnit >= 256)) {
          commands.add(new PushNewTwoByteString(new Uint16List.fromList(list)));
        } else {
          commands.add(new PushNewOneByteString(new Uint8List.fromList(list)));
        }
      } else if (constant.isList) {
        addList(constant.entries, true);
      } else if (constant.isMap) {
        MapConstantValue value = constant;
        addList(value.keys, false);
        addList(value.values, false);
        commands.add(new PushConstantMap(value.length * 2));
      } else if (constant.isFunction) {
        FunctionConstantValue value = constant;
        FunctionElement element = value.element;
        DartinoFunctionBase function = lookupFunctionByElement(element);
        int tearoffId = lookupTearOffById(function.functionId);
        DartinoFunctionBase tearoff = lookupFunction(tearoffId);
        commands
            ..add(new PushFromMap(MapId.classes, tearoff.memberOf))
            ..add(const PushNewInstance());
      } else if (constant.isConstructedObject) {
        ConstructedConstantValue value = constant;
        ClassElement classElement = value.type.element;
        // TODO(ajohnsen): Avoid usage of builders (should be DartinoClass).
        DartinoClassBuilder classBuilder =
            _classBuildersByElement[classElement];

        void addIfInstanceField(MemberElement member) {
          if (!member.isField || member.isStatic || member.isPatch) return;
          FieldElement fieldElement = member;
          ConstantValue fieldValue = value.fields[fieldElement];
          int fieldId = lookupConstantIdByValue(fieldValue);
          commands.add(new PushFromMap(MapId.constants, fieldId));
        }

        // Adds all the fields of [currentClass] in order starting from the top
        // of the inheritance chain, and for each class adds non-patch fields
        // before patch fields.
        void addFields(ClassElement currentClass) {
          if (currentClass.superclass != null) {
            addFields(currentClass.superclass);
          }
          currentClass.forEachLocalMember(addIfInstanceField);
          if (currentClass.isPatched) {
            currentClass.patch.forEachLocalMember(addIfInstanceField);
          }
        }

        addFields(classElement);

        commands
            ..add(new PushFromMap(MapId.classes, classBuilder.classId))
            ..add(const PushNewInstance());
      } else if (constant is DartinoClassInstanceConstant) {
        commands
            ..add(new PushFromMap(MapId.classes, constant.classId))
            ..add(const PushNewInstance());
      } else if (constant.isType) {
        // TODO(kasperl): Implement proper support for class literals. At this
        // point, we've already issues unimplemented errors for the individual
        // accesses to the class literals, so we just let the class literal
        // turn into null in the runtime.
        commands.add(const PushNull());
      } else {
        throw "Unsupported constant: ${constant.toStructuredString()}";
      }
      DartinoConstant dartinoConstant =
        new DartinoConstant(id, MapId.constants);
      constantsByValue = constantsByValue.insert(constant, dartinoConstant);
      constantsById = constantsById.insert(id, dartinoConstant);
      commands.add(new PopToMap(MapId.constants, id));
    });

    // Set super class for classes, now they are resolved.
    for (DartinoClass klass in classes) {
      if (!klass.hasSuperclassId) continue;
      commands.add(new PushFromMap(MapId.classes, klass.classId));
      commands.add(new PushFromMap(MapId.classes, klass.superclassId));
      commands.add(const ChangeSuperClass());
      changes++;
    }

    // Key is function id, and its corresponding value is a set of functions
    // whose literal tables contain references to the key.
    PersistentMap<int, PersistentSet<int>> functionBackReferences =
      predecessorSystem.functionBackReferences;

    void addFunctionBackReference(
        DartinoFunctionBase user,
        DartinoConstant used) {
      PersistentSet<int> referrers = functionBackReferences[used.id];
      if (referrers == null) {
        referrers = new PersistentSet<int>();
      }
      referrers = referrers.insert(user.functionId);
      functionBackReferences =
          functionBackReferences.insert(used.id, referrers);
    }

    void removeFunctionBackReference(
        DartinoFunctionBase user,
        DartinoConstant used) {
      PersistentSet<int> referrers = functionBackReferences[used.id];
      if (referrers == null) return;
      referrers = referrers.delete(user.functionId);
      functionBackReferences =
          functionBackReferences.insert(used.id, referrers);
    }

    // Change constants for the functions, now that classes and constants have
    // been added.
    for (DartinoFunction function in functions) {
      List<DartinoConstant> constants = function.constants;
      for (int i = 0; i < constants.length; i++) {
        DartinoConstant constant = constants[i];
        commands
            ..add(new PushFromMap(MapId.methods, function.functionId))
            ..add(new PushFromMap(constant.mapId, constant.id))
            ..add(new ChangeMethodLiteral(i));
        changes++;
        if (constant.mapId == MapId.methods) {
          addFunctionBackReference(function, constant);
        }
      }
    }

    // Compute all scheme changes.
    for (DartinoClassBuilder builder in _newClasses.values) {
      if (builder.computeSchemaChange(commands)) changes++;
    }

    List<DartinoFunction> changedFunctions = <DartinoFunction>[];
    for (int user in _replaceUsage.keys) {
      // Don't modify already replaced elements.
      DartinoFunction function = predecessorSystem.lookupFunctionById(user);
      if (function == null) continue;
      if (lookupFunctionBuilderByElement(function.element) != null) continue;
      if (_removedFunctions.contains(function)) continue;

      bool constantsChanged = false;
      List<DartinoConstant> constants = function.constants.toList();
      for (int i = 0; i < constants.length; i++) {
        DartinoConstant constant = constants[i];
        if (constant.mapId != MapId.methods) continue;
        for (int usage in _replaceUsage[user]) {
          if (usage != constant.id) continue;
          DartinoFunction oldFunction =
              predecessorSystem.lookupFunctionById(usage);
          if (oldFunction == null || oldFunction.element == null) continue;
          DartinoFunctionBuilder newFunction =
              lookupFunctionBuilderByElement(oldFunction.element);

          // If the method didn't really change, ignore.
          if (newFunction == null) continue;

          constant = new DartinoConstant(newFunction.functionId, MapId.methods);
          commands
              ..add(new PushFromMap(MapId.methods, function.functionId))
              ..add(new PushFromMap(constant.mapId, constant.id))
              ..add(new ChangeMethodLiteral(i));
          addFunctionBackReference(function, constant);
          constants[i] = constant;
          constantsChanged = true;
          changes++;
          break;
        }
      }

      if (constantsChanged) {
        changedFunctions.add(function.withReplacedConstants(constants));
      }
    }

    commands.add(new CommitChanges(changes));

    PersistentMap<int, DartinoClass> classesById =
        predecessorSystem.classesById;
    PersistentMap<ClassElement, DartinoClass> classesByElement =
        predecessorSystem.classesByElement;

    for (DartinoClass klass in classes) {
      classesById = classesById.insert(klass.classId, klass);
      if (klass.element != null) {
        classesByElement = classesByElement.insert(klass.element, klass);
      }
    }

    PersistentMap<int, DartinoFunction> functionsById =
        predecessorSystem.functionsById;
    PersistentMap<Element, DartinoFunction> functionsByElement =
        predecessorSystem.functionsByElement;

    for (DartinoFunction function in changedFunctions) {
      assert(functionsById[function.functionId] != null);
      functionsById = functionsById.insert(function.functionId, function);
      Element element = function.element;
      if (element != null) {
        assert(functionsByElement[element] != null);
        functionsByElement = functionsByElement.insert(element, function);
      }
    }

    for (DartinoFunction function in _removedFunctions) {
      functionsById = functionsById.delete(function.functionId);
      Element element = function.element;
      if (element != null) {
        functionsByElement = functionsByElement.delete(element);
      }
      for (DartinoConstant constant in function.constants) {
        if (constant.mapId != MapId.methods) continue;
        removeFunctionBackReference(function, constant);
      }
      functionBackReferences =
          functionBackReferences.delete(function.functionId);
    }

    for (DartinoFunction function in functions) {
      functionsById = functionsById.insert(function.functionId, function);
    }

    _functionBuildersByElement.forEach((element, builder) {
      functionsByElement = functionsByElement.insert(
          element,
          functionsById[builder.functionId],
          (oldValue, newValue) {
            throw "Unexpected element in predecessorSystem.";
          });
    });

    PersistentMap<ConstructorElement, DartinoFunction>
        constructorInitializersByElement =
            predecessorSystem.constructorInitializersByElement;

    _newConstructorInitializers.forEach((element, builder) {
      constructorInitializersByElement =
          constructorInitializersByElement.insert(
              element, functionsById[builder.functionId]);
    });

    PersistentMap<FieldElement, int> lazyFieldInitializerByElement =
        predecessorSystem.lazyFieldInitializersByElement;

    _newLazyInitializersByElement.forEach((field, functionId) {
      DartinoFunctionBase initializerFunction = null;
      if (field.initializer != null)  {
        initializerFunction = functionsById[functionId];
      }

      lazyFieldInitializerByElement =
          lazyFieldInitializerByElement.insert(
              field, initializerFunction?.functionId);
    });

    PersistentMap<int, int> tearoffsById = predecessorSystem.tearoffsById.union(
        new PersistentMap<int, int>.fromMap(_newTearoffsById));

    PersistentMap<int, int> tearoffGettersById =
        predecessorSystem.tearoffGettersById.union(
            new PersistentMap<int, int>.fromMap(_newTearoffGettersById));

    PersistentMap<int, String> symbolByDartinoSelectorId =
        predecessorSystem.symbolByDartinoSelectorId.union(
            new PersistentMap<int, String>.fromMap(_symbolByDartinoSelectorId));

    PersistentMap<int, int> gettersByFieldIndex =
        predecessorSystem.gettersByFieldIndex.union(
            new PersistentMap<int, int>.fromMap(_newGettersByFieldIndex));

    PersistentMap<int, int> settersByFieldIndex =
        predecessorSystem.settersByFieldIndex.union(
            new PersistentMap<int, int>.fromMap(_newSettersByFieldIndex));

    PersistentMap<ParameterStubSignature, DartinoFunction> parameterStubs =
        predecessorSystem.parameterStubs;
    _newParameterStubs.forEach((signature, functionBuilder) {
      DartinoFunction function = functionsById[functionBuilder.functionId];
      parameterStubs = parameterStubs.insert(signature, function);
    });

    PersistentMap<int, PersistentSet<DartinoFunction>> parameterStubsById =
        predecessorSystem.parameterStubsById;
    _newParameterStubsById.forEach(
        (int functionId, Set<DartinoFunctionBase> newStubs) {
      PersistentSet<DartinoFunction> stubs = parameterStubsById[functionId];
      if (stubs == null) {
        stubs = new PersistentSet<DartinoFunction>();
      }
      newStubs.forEach((DartinoFunctionBase stub) {
        DartinoFunction function = functionsById[stub.functionId];
        stubs = stubs.insert(function);
      });
      parameterStubsById = parameterStubsById.insert(functionId, stubs);
    });

    PersistentSet<String> names = predecessorSystem.names == null
        ? new PersistentSet<String>.from(_names)
        : predecessorSystem.names.union(new PersistentSet<String>.from(_names));

    PersistentMap<LibraryElement, String> libraryTag =
        predecessorSystem.libraryTag.union(
            new PersistentMap<LibraryElement, String>.fromMap(_libraryTag));

    List<String> symbols = new List<String>.unmodifiable(
        new List<String>.from(predecessorSystem.symbols)..addAll(_symbols));

    PersistentMap<String, int> symbolIds = predecessorSystem.symbolIds.union(
        new PersistentMap<String, int>.fromMap(_symbolIds));

    PersistentMap<Selector, String> selectorToSymbol =
        predecessorSystem.selectorToSymbol.union(
            new PersistentMap<Selector, String>.fromMap(_selectorToSymbol));

    PersistentMap<FieldElement, int> staticFieldsById =
        predecessorSystem.staticFieldsById.union(
            new PersistentMap<FieldElement, int>.fromMap(_newStaticFieldsById));

    return new DartinoSystem(
        functionsById,
        functionsByElement,
        constructorInitializersByElement,
        lazyFieldInitializerByElement,
        tearoffsById,
        tearoffGettersById,
        classesById,
        classesByElement,
        constantsById,
        constantsByValue,
        symbolByDartinoSelectorId,
        gettersByFieldIndex,
        settersByFieldIndex,
        parameterStubs,
        parameterStubsById,
        functionBackReferences,
        names,
        libraryTag,
        symbols,
        symbolIds,
        selectorToSymbol,
        staticFieldsById);
  }

  bool get hasChanges {
    var changes = [
      _newFunctions,
      _newClasses,
      _newConstants,
      _newParameterStubs,
      _newGettersByFieldIndex,
      _newSettersByFieldIndex,
      _removedFunctions,
      _functionBuildersByElement,
      _classBuildersByElement,
      _newConstructorInitializers,
      _replaceUsage,
      _newLazyInitializersByElement,
      _newTearoffsById,
      _symbolByDartinoSelectorId,
      _names,
      _libraryTag,
      _symbols,
      _symbolIds,
      _selectorToSymbol];
    return changes.any((c) => c.isNotEmpty);
  }
}

class SchemaChange {
  final ClassElement cls;
  final List<FieldElement> addedFields = <FieldElement>[];
  final List<FieldElement> removedFields = <FieldElement>[];

  int extraSuperFields = 0;

  SchemaChange(this.cls);

  void addRemovedField(FieldElement field) {
    if (field.enclosingClass != cls) extraSuperFields--;
    removedFields.add(field);
  }

  void addAddedField(FieldElement field) {
    if (field.enclosingClass != cls) extraSuperFields++;
    addedFields.add(field);
  }

  void addSchemaChange(SchemaChange other) {
    for (FieldElement field in other.addedFields) {
      addAddedField(field);
    }
    for (FieldElement field in other.removedFields) {
      addRemovedField(field);
    }
  }
}
