/* Copyright (C) OnePub IP Pty Ltd - All Rights Reserved
 * Unauthorized copying of this file, via any medium is strictly prohibited
 * Proprietary and confidential
 * Written by Brett Sutton <bsutton@onepub.dev>, Jan 2022
 */

import 'package:dcli/dcli.dart';

// ignore: avoid_classes_with_only_static_members
class MySQLParser {
  /// Takes the results of running an sql command on the cli
  /// returning RecordSet with the parsed data.
  /// +-----+---------------+----------------------------------+
  /// | iId | vLogin        | vPassword                        |
  /// +-----+---------------+----------------------------------+
  /// |   1 | Administrator | asf3ad;lbh                       |
  /// |   2 | Receptionist  | skas;ljaa sd                     |
  /// +-----+---------------+----------------------------------+
  static RecordSet parseResults(List<String> results) {
    final recordSet = RecordSet();

    var headerSeen = false;
    for (final row in results) {
      if (row.isNotEmpty) {
        if (!row.startsWith('+') && !row.startsWith('|')) {
          printerr(red(row));
        } else {
          if (!row.startsWith('+')) {
            if (!headerSeen) {
              recordSet.headings = Field.parseHeadings(row);
              headerSeen = true;
            } else {
              recordSet.addRow(Row.parseRow(row, recordSet.headings));
            }
          }
        }
      }
    }
    return recordSet;
  }

  /// Pulls the column data out of the row returning
  /// a list of the field data.
  static List<String> parseLine(String row) {
    final columns = <String>[];
    row = row.trim();

    // each row has a leading and trailing |
    if (row.substring(0, 1) == '|' &&
        row.substring(row.length - 1, row.length) == '|') {
      row = row.substring(1, row.length - 1);
      final fields = row.split('|');
      for (final field in fields) {
        columns.add(field.trim());
      }
    }
    return columns;
  }
}

class RecordSet {
  RecordSet();
  List<Field> headings = <Field>[];
  final List<Row> _rows = [];

  List<Row> get rows => _rows;

  List<String> get headingNames =>
      headings.map((heading) => heading.name).toList();

  void addRow(Row row) {
    _rows.add(row);
  }
}

/// describes the db field.
class Field {
  Field(this.name);
  String name;

  static List<Field> parseHeadings(String line) {
    final fields = <Field>[];
    final headings = MySQLParser.parseLine(line);
    for (final heading in headings) {
      fields.add(Field(heading));
    }
    return fields;
  }
}

class Row {
  Row(this.fieldValues);
  Row.parseRow(String line, List<Field> headings) {
    final values = MySQLParser.parseLine(line);
    var i = 0;
    for (final value in values) {
      final heading = headings[i];
      fieldValues.add(FieldValue(
        heading,
        value,
      ));
      i++;
    }
  }

  List<FieldValue> fieldValues = [];

  List<String> get values => fieldValues.map((field) => field.value).toList();
}

///
class FieldValue {
  FieldValue(this.field, this.value);
  final Field field;
  final String value;
}
