/* Copyright (C) OnePub IP Pty Ltd - All Rights Reserved
 * Unauthorized copying of this file, via any medium is strictly prohibited
 * Proprietary and confidential
 * Written by Brett Sutton <bsutton@onepub.dev>, Jan 2022
 */

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
    var borders = 0;
    for (final row in results) {
      if (row.isEmpty) {
        continue;
      }
      if (RegExp(r'^\+(?:-+\+)+$').hasMatch(row)) {
        borders++;
        if (borders > 3) {
          throw const FormatException('Multiple or malformed tables.');
        }
      } else if (borders == 1 && recordSet.headings.isEmpty) {
        recordSet.headings = Field.parseHeadings(row);
        if (recordSet.headings.isEmpty) {
          throw const FormatException('Invalid table header.');
        }
      } else if (borders == 2 && recordSet.headings.isNotEmpty) {
        recordSet.addRow(Row.parseRow(row, recordSet.headings));
      } else {
        throw const FormatException('Unexpected table output.');
      }
    }
    if (borders != 0 && borders != 3) {
      throw const FormatException('Incomplete table.');
    }
    return recordSet;
  }

  /// Parses mysql's escaped, tab-separated batch output without trimming.
  /// SQL NULL and the text "NULL" are indistinguishable in this format.
  /// Headings are emitted verbatim by the client, so aliases must not contain
  /// tabs or line feeds: these are indistinguishable from format delimiters.
  /// The caller must supply exactly one result set, split at LF only, with
  /// carriage returns preserved and no extra line for the final LF.
  static RecordSet parseBatch(List<String> lines) {
    final result = RecordSet();
    if (lines.isEmpty) {
      return result;
    }
    result.headings = lines.first.split('\t').map(Field.new).toList();
    for (final line in lines.skip(1)) {
      final values = line.split('\t').map(_decode).toList();
      result.addRow(Row.fromValues(values, result.headings));
    }
    return result;
  }

  static String _decode(String value) {
    final out = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      if (value[i] != r'\') {
        out.write(value[i]);
        continue;
      }
      if (++i == value.length) {
        throw const FormatException('Invalid batch escape.');
      }
      switch (value[i]) {
        case 'n':
          out.write('\n');
          break;
        case 't':
          out.write('\t');
          break;
        case '0':
          out.write('\x00');
          break;
        case r'\':
          out.write(r'\');
          break;
        default:
          throw const FormatException('Invalid batch escape.');
      }
    }
    return out.toString();
  }

  /// Pulls the column data out of the row returning
  /// a list of the field data.
  static List<String> parseLine(String row) {
    final columns = <String>[];
    row = row.trim();

    // each row has a leading and trailing |
    if (row.length >= 2 && row.startsWith('|') && row.endsWith('|')) {
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
  Row.parseRow(String line, List<Field> headings)
      : this.fromValues(MySQLParser.parseLine(line), headings);

  Row.fromValues(List<String> values, List<Field> headings) {
    if (values.length != headings.length || headings.isEmpty) {
      throw const FormatException('Result column count does not match header.');
    }
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
