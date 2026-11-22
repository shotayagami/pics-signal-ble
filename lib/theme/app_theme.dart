import 'package:flutter/material.dart';

ThemeData buildTheme(Brightness b) => ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: b,
      useMaterial3: true,
    );
