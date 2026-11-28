import 'package:flutter/material.dart';

// RustAdmin: the defaults of Row and Column are written out. `const Row().mainAxisAlignment`
// fails to compile with assertions on (tests, debug builds) since Flutter 3.50: the
// constant evaluator rejects the enum comparison in Flex's assert.

/// A widget that displays its children in a row or column based on the value of isVertical (toggle switch type).
class RowToColumn extends StatelessWidget {
  final List<Widget> children;
  final bool isVertical;
  final bool? isColumnToRow;

  final MainAxisAlignment? mainAxisAlignment;
  final MainAxisSize? mainAxisSize;
  final CrossAxisAlignment? crossAxisAlignment;

  const RowToColumn(
      {Key? key,
      required this.children,
      required this.isVertical,
      this.isColumnToRow,
      this.mainAxisAlignment,
      this.mainAxisSize,
      this.crossAxisAlignment})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ((isColumnToRow ?? false) ? isVertical : !isVertical)
        ? Row(
            mainAxisAlignment:
                mainAxisAlignment ?? MainAxisAlignment.start,
            mainAxisSize: mainAxisSize ?? MainAxisSize.max,
            crossAxisAlignment:
                crossAxisAlignment ?? CrossAxisAlignment.center,
            children: children,
          )
        : Column(
            mainAxisAlignment:
                mainAxisAlignment ?? MainAxisAlignment.start,
            mainAxisSize: mainAxisSize ?? MainAxisSize.max,
            crossAxisAlignment:
                crossAxisAlignment ?? CrossAxisAlignment.center,
            children: children,
          );
  }
}
