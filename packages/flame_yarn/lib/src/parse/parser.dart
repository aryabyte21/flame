import 'package:flame_yarn/src/errors.dart';
import 'package:flame_yarn/src/parse/token.dart';
import 'package:flame_yarn/src/parse/tokenize.dart';
import 'package:flame_yarn/src/structure/expressions/arithmetic.dart';
import 'package:flame_yarn/src/structure/expressions/expression.dart';
import 'package:flame_yarn/src/structure/expressions/functions.dart';
import 'package:flame_yarn/src/structure/expressions/literal.dart';
import 'package:flame_yarn/src/structure/expressions/relational.dart';
import 'package:flame_yarn/src/structure/expressions/string.dart';
import 'package:flame_yarn/src/structure/expressions/variables.dart';
import 'package:flame_yarn/src/structure/line.dart';
import 'package:flame_yarn/src/structure/node.dart';
import 'package:flame_yarn/src/structure/statement.dart';
import 'package:flame_yarn/src/yarn_ball.dart';
import 'package:meta/meta.dart';

@internal
void parse(String text, YarnBall project) {
  final tokens = tokenize(text);
  _Parser(project, text, tokens).parse();
}

class _Parser {
  _Parser(this.project, this.text, this.tokens) : position = 0;

  final YarnBall project;
  final String text;
  final List<Token> tokens;

  /// The index of the next token to parse.
  int position;

  bool advance() {
    position += 1;
    return true;
  }

  Token peekToken([int delta = 0]) => tokens[position + delta];

  Token nextToken() {
    final token = tokens[position];
    position += 1;
    return token;
  }

  void returnToken() {
    position -= 1;
  }

  void parse() {
    while (position < tokens.length) {
      final nodeBuilder = _NodeBuilder();
      parseNodeHeader(nodeBuilder);
      parseNodeBody(nodeBuilder);
      assert(!project.nodes.containsKey(nodeBuilder.title));
      project.nodes[nodeBuilder.title!] = nodeBuilder.build();
    }
  }

  void parseNodeHeader(_NodeBuilder node) {
    while (peekToken() != Token.startBody) {
      if (takeId() && take(Token.colon) && takeText() && takeNewline()) {
        final id = peekToken(-4);
        final text = peekToken(-2);
        if (id.content == 'title') {
          node.title = text.content;
          if (project.nodes.containsKey(node.title)) {
            error('node with title ${node.title} has already been defined');
          }
        } else {
          node.tags ??= [];
          node.tags!.add(text.content);
        }
      }
    }
    if (node.title == null) {
      error('node does not have a title');
    }
  }

  void parseNodeBody(_NodeBuilder node) {
    take(Token.startBody);
    if (peekToken() == Token.startIndent) {
      error('unexpected indent');
    }
    parseStatementList(node.statements);
    take(Token.endBody);
  }

  void parseStatementList(List<Statement> out) {
    while (true) {
      final nextToken = peekToken();
      if (nextToken == Token.arrow) {
        parseOption();
      } else if (nextToken == Token.startCommand) {
        parseCommand();
      } else if (nextToken.isText || nextToken.isSpeaker) {
        final lineBuilder = _LineBuilder();
        parseLine(lineBuilder);
        out.add(lineBuilder.build());
      } else {
        break;
      }
    }
  }

  void parseOption() {}

  void parseCommand() {}

  /// Consumes a regular line of text from the input, up to and including the
  /// NEWLINE token.
  void parseLine(_LineBuilder line) {
    maybeParseLineSpeaker(line);
    parseLineContent(line);
    maybeParseLineCondition(line);
    maybeParseHashtags(line);
    if (peekToken() == Token.startCommand) {
      if (line.tags != null) {
        error('the command must come before the hashtags');
      } else {
        error('multiple commands are not allowed on a line');
      }
    }
    takeNewline();
  }

  void maybeParseLineSpeaker(_LineBuilder line) {
    final token = peekToken();
    if (token.isSpeaker) {
      line.speaker = token.content;
      takeSpeaker();
      take(Token.colon);
    }
  }

  void parseLineContent(_LineBuilder line) {
    final parts = <TypedExpression<String>>[];
    while (true) {
      final token = peekToken();
      if (token.isText) {
        parts.add(Literal<String>(token.content));
      } else if (token == Token.startExpression) {
        take(Token.startExpression);
        final expression = parseExpression();
        if (expression.isString) {
          parts.add(expression as StrExpr);
        } else if (expression.isNumeric) {
          parts.add(NumToStringFn(expression as NumExpr));
        } else if (expression.isBoolean) {
          parts.add(BoolToStringFn(expression as BoolExpr));
        }
        take(Token.endExpression);
      } else {
        break;
      }
    }
    if (parts.length == 1) {
      line.content = parts.first;
    } else if (parts.length > 1) {
      line.content = Concat(parts);
    }
  }

  void maybeParseLineCondition(_LineBuilder line) {
    final token = peekToken();
    if (token == Token.startCommand) {
      position += 1;
      if (peekToken() != Token.commandIf) {
        error('only if commands are allowed on a line');
      }
      position += 1;

      take(Token.endCommand);
    }
  }

  void maybeParseHashtags(_LineBuilder line) {
    while (true) {
      final token = peekToken();
      if (token.isHashtag) {
        line.tags ??= [];
        line.tags!.add(token.content);
        position += 1;
      } else {
        break;
      }
    }
  }

  Expression parseExpression() {
    return parseExpression1(parsePrimary(), 0);
  }

  Expression parseExpression1(Expression lhs, int minPrecedence) {
    final position0 = position;
    var result = lhs;
    var token = peekToken();
    while ((precedences[token] ?? -1) >= minPrecedence) {
      final opPrecedence = precedences[token]!;
      final op = token;
      position += 1;
      var rhs = parsePrimary();
      token = peekToken();
      while ((precedences[token] ?? -1) > minPrecedence) {
        rhs = parseExpression1(rhs, opPrecedence + 1);
        token = peekToken();
      }
      result = binaryOperatorConstructors[op]!(lhs, rhs, position0);
    }
    return result;
  }

  Expression parsePrimary() {
    final token = peekToken();
    position += 1;
    if (token == Token.startParenthesis) {
      final expression = parseExpression();
      if (peekToken() != Token.endParenthesis) {
        error('closing ")" is expected');
      }
      return expression;
    } else if (token == Token.operatorMinus) {
      final expression = parsePrimary();
      if (expression is Literal<num>) {
        return Literal<num>(-expression.value);
      } else if (expression.isNumeric) {
        return Negate(expression as NumExpr);
      } else {
        error('unary minus can only be applied to numbers');
      }
    } else if (token.isNumber) {
      return Literal<num>(num.parse(token.content));
    } else if (token.isString) {
      return Literal<String>(token.content);
    } else if (token.isVariable) {
      final name = token.content;
      if (project.variables.hasVariable(name)) {
        final dynamic variable = project.variables.getVariable(name);
        if (variable is num) {
          return NumericVariable(name, project.variables);
        } else if (variable is String) {
          return StringVariable(name, project.variables);
        } else {
          assert(variable is bool);
          return BooleanVariable(name, project.variables);
        }
      } else {
        error('variable $name is not defined');
      }
    } else if (token.isId) {
      // A function call...
    }
    position -= 1;
    return constVoid;
  }

  //----------------------------------------------------------------------------
  // All `take*` methods will consume a single token of the specified kind,
  // advance the parsing [position], and return `true` (for chaining purposes).
  // If, on the other hand, the specified token cannot be found, an exception
  // 'unexpected token' will be thrown.
  //----------------------------------------------------------------------------

  bool takeId() => takeTokenType(TokenType.id);
  bool takeText() => takeTokenType(TokenType.text);
  bool takeSpeaker() => takeTokenType(TokenType.speaker);
  bool takeNewline() => take(Token.newline);

  bool take(Token token) {
    if (tokens[position] == token) {
      position += 1;
      return true;
    }
    return error('unexpected token');
  }

  bool takeTokenType(TokenType type) {
    if (tokens[position].type == type) {
      position += 1;
      return true;
    }
    return error('unexpected token');
  }

  static const Map<Token, int> precedences = {
    Token.operatorMultiply: 6,
    Token.operatorDivide: 6,
    Token.operatorModulo: 6,
    //
    Token.operatorMinus: 5,
    Token.operatorPlus: 5,
    //
    Token.operatorEqual: 4,
    Token.operatorNotEqual: 4,
    Token.operatorGreaterOrEqual: 4,
    Token.operatorGreaterThan: 4,
    Token.operatorLessOrEqual: 4,
    Token.operatorLessThan: 4,
    //
    Token.operatorNot: 3,
    Token.operatorAnd: 2,
    Token.operatorXor: 2,
    Token.operatorOr: 1,
  };

  late Map<Token, Expression Function(Expression, Expression, int)>
      binaryOperatorConstructors = {
    Token.operatorDivide: _divide,
    Token.operatorMinus: _subtract,
    Token.operatorModulo: _modulo,
    Token.operatorMultiply: _multiply,
    Token.operatorPlus: _add,
    Token.operatorEqual: _equal,
  };

  Expression _add(Expression lhs, Expression rhs, int opPosition) {
    if (lhs.isNumeric && rhs.isNumeric) {
      return Add(lhs as NumExpr, rhs as NumExpr);
    }
    if (lhs.isString && rhs.isString) {
      return Concat([lhs as StrExpr, rhs as StrExpr]);
    }
    position = opPosition;
    error('both lhs and rhs of + must be numeric or strings');
  }

  Expression _subtract(Expression lhs, Expression rhs, int opPosition) {
    if (lhs.isNumeric && rhs.isNumeric) {
      return Subtract(lhs as NumExpr, rhs as NumExpr);
    }
    if (lhs.isString && rhs.isString) {
      return Remove(lhs as StrExpr, rhs as StrExpr);
    }
    position = opPosition;
    error('both lhs and rhs of - must be numeric or strings');
  }

  Expression _multiply(Expression lhs, Expression rhs, int opPosition) {
    if (lhs.isNumeric && rhs.isNumeric) {
      return Multiply(lhs as NumExpr, rhs as NumExpr);
    }
    if (lhs.isString && rhs.isNumeric) {
      return Repeat(lhs as StrExpr, rhs as NumExpr);
    }
    position = opPosition;
    error('both lhs and rhs of * must be numeric');
  }

  Expression _divide(Expression lhs, Expression rhs, int opPosition) {
    if (lhs.isNumeric && rhs.isNumeric) {
      return Divide(lhs as NumExpr, rhs as NumExpr);
    }
    position = opPosition;
    error('both lhs and rhs of / must be numeric');
  }

  Expression _modulo(Expression lhs, Expression rhs, int opPosition) {
    if (lhs.isNumeric && rhs.isNumeric) {
      return Modulo(lhs as NumExpr, rhs as NumExpr);
    }
    position = opPosition;
    error('both lhs and rhs of % must be numeric');
  }

  Expression _equal(Expression lhs, Expression rhs, int opPosition) {
    if (lhs.isNumeric && rhs.isNumeric) {
      return NumericEqual(lhs as NumExpr, rhs as NumExpr);
    }
    if (lhs.isString && rhs.isString) {
      return StringEqual(lhs as StrExpr, rhs as StrExpr);
    }
    if (lhs.isBoolean && rhs.isBoolean) {
      return BoolEqual(lhs as BoolExpr, rhs as BoolExpr);
    }
    position = opPosition;
    error(
      'equality operator between operands of unrelated types ${lhs.type} '
      'and ${rhs.type}',
    );
  }

  Never error(String message) {
    throw SyntaxError(message);
  }
}

class _NodeBuilder {
  String? title;
  List<String>? tags;
  List<Statement> statements = [];

  Node build() => Node(
        title: title!,
        tags: tags,
        lines: statements,
      );
}

class _LineBuilder {
  String? speaker;
  TypedExpression<String>? content;
  TypedExpression<bool>? condition;
  List<String>? tags;

  Line build() => Line(
        speaker: speaker,
        content: content ?? constEmptyString,
        condition: condition,
        tags: tags,
      );
}

typedef NumExpr = TypedExpression<num>;
typedef StrExpr = TypedExpression<String>;
typedef BoolExpr = TypedExpression<bool>;
