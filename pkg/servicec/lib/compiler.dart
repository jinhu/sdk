// Copyright (c) 2015, the Fletch project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library servicec.compiler;

import 'dart:io';

import 'errors.dart';

import 'targets.dart' show
    Target;

void compile(String path, [String outputDirectory, Target target]) {
  String input = new File(path).readAsStringSync();
  compileInput(input, path, outputDirectory, target);
}

void compileInput(
    String input,
    String path,
    [String outputDirectory,
     Target target]) {
  if (input.isEmpty)
    throw new UndefinedServiceError(path);
}
