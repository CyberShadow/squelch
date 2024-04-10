module squelch.lex;

import std.algorithm.comparison;
import std.algorithm.mutation : reverse;
import std.algorithm.searching;
import std.array;
import std.ascii;
import std.conv : to;
import std.conv;
import std.exception;
import std.functional;
import std.range.primitives;
import std.stdio : stderr;
import std.string : representation, splitLines, strip;
import std.sumtype : match;
import std.uni : icmp, toUpper, toLower;

import ae.utils.array;
import ae.utils.text;

import squelch.common;

immutable string[] operators =
[
	"+", "-", "*", "/",
	";",
	",",
	"(", ")",
	"[", "]",
	"<", ">",
	".",
	"&", "^", "|",
	"=", "<>", "!=", "<=", ">=",
	"||",
	"~",
	"<<", ">>",
	"=>",
];

// https://cloud.google.com/bigquery/docs/reference/standard-sql/lexical#reserved_keywords
immutable string[] keywords =
[
	"ALL",
	"AND",
	"ANY",
	"ARRAY",
	"AS",
	"ASC",
	"ASSERT_ROWS_MODIFIED",
	"AT",
	"BETWEEN",
	"BY",
	"CASE",
	"CAST",
	"COLLATE",
	"CONTAINS",
	"CREATE",
	"CROSS",
	"CUBE",
	"CURRENT",
	"DEFAULT",
	"DEFINE",
	"DESC",
	"DISTINCT",
	"ELSE",
	"END",
	"ENUM",
	"ESCAPE",
	"EXCEPT",
	"EXCLUDE",
	"EXISTS",
	"EXTRACT",
	"FALSE",
	"FETCH",
	"FOLLOWING",
	"FOR",
	"FROM",
	"FULL",
	"GROUP",
	"GROUPING",
	"GROUPS",
	"HASH",
	"HAVING",
	"IF",
	"IGNORE",
	"IN",
	"INNER",
	"INTERSECT",
	"INTERVAL",
	"INTO",
	"IS",
	"JOIN",
	"LATERAL",
	"LEFT",
	"LIKE",
	"LIMIT",
	"LOOKUP",
	"MERGE",
	"NATURAL",
	"NEW",
	"NO",
	"NOT",
	"NULL",
	"NULLS",
	"OF",
	"ON",
	"OR",
	"ORDER",
	"OUTER",
	"OVER",
	"PARTITION",
	"PRECEDING",
	"PROTO",
	"QUALIFY",
	"RANGE",
	"RECURSIVE",
	"RESPECT",
	"RIGHT",
	"ROLLUP",
	"ROWS",
	"SELECT",
	"SET",
	"SOME",
	"STRUCT",
	"TABLESAMPLE",
	"THEN",
	"TO",
	"TREAT",
	"TRUE",
	"UNBOUNDED",
	"UNION",
	"UNNEST",
	"USING",
	"WHEN",
	"WHERE",
	"WINDOW",
	"WITH",
	"WITHIN",
];

bool isIdentifier(char c) { return isAlphaNum(c) || c == '_'; }
bool isIdentifierStart(char c) { return isAlpha(c) || c == '_'; }
bool isIdentifierContinuation(char c) { return isIdentifier(c) || c == '-'; }

Token[] lex(string s, Dialect dialect)
{
	Token[] tokens;

tokenLoop:
	while (s.length)
	{
		// TokenWhiteSpace
		if (isWhite(s[0]))
		{
			auto text = s.skipWhile!isWhite(true);
			// tokens ~= Token(TokenWhiteSpace(text));
			continue tokenLoop;
		}

		// TokenComment
		if (s.skipOver("--") || s.skipOver("#"))
		{
			auto text = s.skipUntil("\n", true);
			text.skipOver(" ");
			tokens ~= Token(TokenComment(text));
			continue tokenLoop;
		}

		if (s.skipOver("/*"))
		{
			auto text = s.skipUntil("*/").enforce("Unterminated comment");
			text.skipOver(" ");
			foreach (line; text.splitLines)
				tokens ~= Token(TokenComment(line));
			continue tokenLoop;
		}

		// TokenString / quoted TokenIdentifier
		{
			size_t i;
			bool raw, bytes;
			string quote;

			while (i < s.length)
			{
				if (dialect == Dialect.bigquery && toUpper(s[i]) == 'R')
				{
					raw = true;
					i++;
					continue;
				}
				if (dialect == Dialect.bigquery && toUpper(s[i]) == 'B')
				{
					bytes = true;
					i++;
					continue;
				}
				if (s[i].among('\'', '"', '`') || (dialect == Dialect.duckdb && s[i..$].startsWith("$$")))
				{
					s = s[i .. $];
					if (dialect == Dialect.bigquery && s.length > 3 && s[1] == s[0] && s[2] == s[0])
					{
						quote = s[0 .. 3];
						s = s[3 .. $];
					}
					else
					if (dialect == Dialect.duckdb && s[0] == '$')
					{
						quote = s[0 .. 2];
						s = s[2 .. $];
						assert(quote == "$$");
						raw = true;
					}
					else
					{
						quote = s[0 .. 1];
						s = s[1 .. $];
					}

					// Parse string contents
					DbtString text;
					while (true)
					{
						enforce(s.length, "Unterminated string");
						if (s.skipOver(quote))
						{
							if (dialect == Dialect.duckdb && quote.length == 1 && s.skipOver(quote))
							{
								foreach (c; quote)
									text ~= DbtStringElem(c);
								continue;
							}

							if (quote[0] == '`')
							{
								enforce(!raw && !bytes && quote.length == 1, "Invalid quoted identifier");
								tokens ~= Token(TokenIdentifier(text));
							}
							else
								tokens ~= Token(TokenString(text, bytes));
							continue tokenLoop;
						}

						if (s.readDbtExpression(text, QuotingContext(quote, raw)))
							continue;

						if (!raw && s.skipOver("\\"))
						{
							enforce(s.length, "Unterminated string");
							auto c = s.shift;
							switch (c)
							{
								case 'a': text ~= DbtStringElem('\a'); continue;
								case 'b': text ~= DbtStringElem('\b'); continue;
								case 'f': text ~= DbtStringElem('\f'); continue;
								case 'n': text ~= DbtStringElem('\n'); continue;
								case 'r': text ~= DbtStringElem('\r'); continue;
								case 't': text ~= DbtStringElem('\t'); continue;
								case 'v': text ~= DbtStringElem('\v'); continue;
								case '\\':
								case '\?':
								case '\"':
								case '\'':
								case '`': text ~= DbtStringElem(c); continue;
								case '0': .. case '7':
									enforce(s.length > 2, "Unterminated string");
									enforce(s[0].isOneOf("01234567"), "Invalid string escape");
									enforce(s[1].isOneOf("01234567"), "Invalid string escape");
									s = s[2 .. $];
									text ~= DbtStringElem((c - '0') * 8 * 8 + (s[0] - '0') * 8 + (s[1] - '0'));
									continue;
								case 'x':
								case 'X':
								case 'u':
								case 'U':
									auto length =
										c == 'U' ? 8 :
										c == 'u' ? 4 :
										2;
									enforce(s.length > length, "Unterminated string");
									uint u;
									foreach (n; 0 .. length)
										u = u * 16 + fromHex(s.shift(1));
									text ~= DbtStringElem(dchar(u));
									continue;
								default:
									enforce(false, "Invalid string escape");
							}

							assert(false);
						}

						text ~= DbtStringElem(s.front);
						s.popFront();
					}
				}
				break;
			}
		}

		// TokenNumber
		if ({
			auto q = s;
			q.skipOver("-");
			q.skipOver(".");
			return q.length && isDigit(q[0]);
		}())
		{
			auto text = s.skipWhile!((char c) => c.isOneOf("0123456789abcdefABCDEFxX-."));
			tokens ~= Token(TokenNumber(text.toLower));
			continue tokenLoop;
		}

		// TokenKeyword
		if (isAlpha(s[0]))
			foreach_reverse (keyword; keywords)
				if (s.length >= keyword.length &&
					icmp(keyword, s[0 .. keyword.length]) == 0 &&
					(s.length == keyword.length || !isIdentifier(s[keyword.length])))
				{
					tokens ~= Token(TokenKeyword(keyword));
					s = s[keyword.length .. $];
					continue tokenLoop;
				}

		// TokenIdentifier
		if (isIdentifierStart(s[0]) || s.startsWith("{{"))
		{
			DbtString text;
			bool raw = dialect == Dialect.duckdb;
			while (s.length)
			{
				if (s.readDbtExpression(text, QuotingContext(null, raw)))
					continue;
				if (!isIdentifierContinuation(s[0]))
					break;
				text ~= DbtStringElem(s.front);
				s.popFront();
			}
			tokens ~= Token(TokenIdentifier(text));
			continue tokenLoop;
		}

		// TokenDbtStatement
		if (s.skipOver("{%"))
		{
			auto text = s.skipUntil("%}");
			auto kind = text;
			kind.skipOver("-") || kind.skipOver("+");
			kind = kind.strip;
			kind = kind.skipWhile!isIdentifier(true);
			tokens ~= Token(TokenDbtStatement(text, kind));
			continue tokenLoop;
		}

		// TokenDbtComment
		if (s.skipOver("{#"))
		{
			tokens ~= Token(TokenDbtComment(s.skipUntil("#}")));
			continue tokenLoop;
		}

		// TokenOperator
		foreach_reverse (operator; operators)
			if (s.startsWith(operator))
			{
				s = s[operator.length .. $];

				// Normalize operators
				string token = {
					switch (operator)
					{
						case "<>":
							return "!=";
						default:
							return operator;
					}
				}();

				tokens ~= Token(TokenOperator(token));
				continue tokenLoop;
			}

		throw new Exception("Unrecognized syntax: " ~ s[0..min(20, $)]);
	}

	// Process contextual keywords

	// NUMERIC / BIGNUMERIC (in numeric literals)
	// https://cloud.google.com/bigquery/docs/reference/standard-sql/lexical#numeric_literals
	foreach (i; 1 .. tokens.length)
	{
		bool isString = tokens[i].match!((ref TokenString _) => true, (ref _) => false);
		if (isString)
		{
			auto kwd = tokens[i - 1].match!((ref TokenIdentifier t) => t.text, _ => null).tryToString.toUpper;
			if (kwd.among("NUMERIC", "BIGNUMERIC"))
				tokens[i - 1] = Token(TokenKeyword(kwd));
		}
	}

	// RETURNS (in function declarations)
	foreach (i; 1 .. tokens.length)
	{
		bool isCloseParen = tokens[i - 1].match!((ref TokenOperator t) => t.text == ")", (ref _) => false);
		auto kwd = tokens[i].match!((ref TokenIdentifier t) => t.text, _ => null).tryToString.toUpper;
		if (isCloseParen && kwd == "RETURNS")
			tokens[i] = Token(TokenKeyword(kwd));
	}

	// WITH OFFSET
	foreach_reverse (i; 1 .. tokens.length)
	{
		bool isWith = tokens[i - 1] == Token(TokenKeyword("WITH"));
		auto kwd = tokens[i].match!((ref TokenIdentifier t) => t.text, _ => null).tryToString.toUpper;
		if (isWith && kwd == "OFFSET")
			tokens = tokens[0 .. i - 1] ~ Token(TokenKeyword("WITH OFFSET")) ~ tokens[i + 1 .. $];
	}

	// Process keyword sequences which act like one keyword (e.g. "ORDER BY")
	{
		// Whether to join tokens[i-1] and tokens[i], and the kind to use for the joined keyword
		auto join = new string[tokens.length + 1];

		void scan(bool forward, string[] headKwds, string[] tailKwds, string kind = null)
		{
			string joinKind;
			for (size_t tokenIndex = forward ? 0 : tokens.length - 1;
				 tokenIndex < tokens.length;
				 tokenIndex += forward ? +1 : -1)
			{
				auto kwd = tokens[tokenIndex].match!(
					(ref const TokenKeyword t) => t.text,
					(ref const TokenIdentifier t) => t.text.tryToString,
					(ref const _) => null,
				);

				if (joinKind)
				{
					if (kwd && tailKwds.canFind(kwd))
					{
						join[tokenIndex + (forward ? 0 : +1)] = joinKind;
						continue;
					}
					else
						joinKind = null;
				}

				if (!joinKind && kwd && headKwds.canFind(kwd))
					joinKind = kind ? kind : kwd;
			}
		}

		scan(true, ["SELECT"], ["DISTINCT", "AS"]);
		scan(true, ["AS"], ["STRUCT"]);
		scan(true, ["UNION", "INTERSECT", "EXCEPT"], ["ALL", "DISTINCT"]);
		scan(true, ["IS"], ["NOT", "NULL", "TRUE", "FALSE"], "IS_X");
		scan(true, ["CREATE"], ["OR", "REPLACE"]);

		scan(false, ["BY"], ["GROUP", "ORDER", "PARTITION"]);
		scan(false, ["JOIN"], ["FULL", "CROSS", "LEFT", "RIGHT", "INNER", "OUTER"]);
		scan(false, ["LIKE", "BETWEEN", "IN"], ["NOT"]);

		{
			Token[] outTokens;
			TokenKeyword k;

			foreach (tokenIndex, ref token; tokens)
			{
				if (join[tokenIndex])
					token.match!(
						(ref const TokenKeyword t) { k.text ~= " " ~ t.text; },
						(ref const TokenIdentifier t) { k.text ~= " " ~ t.text.tryToString; },
						(ref const _) { assert(false); },
					);
				else
				{
					if (k.text)
					{
						outTokens ~= Token(k);
						k = TokenKeyword.init;
					}

					if (join[tokenIndex + 1])
						token.match!(
							(ref const TokenKeyword t) { k = TokenKeyword(join[tokenIndex + 1], t.text); },
							(ref const _) { assert(false); },
						);
					else
						outTokens ~= token;
				}
			}

			if (k.text)
				outTokens ~= Token(k);

			tokens = outTokens;
		}
	}

	// Handle special role of < and > after ARRAY/STRUCT
	{
		int depth;
		for (size_t i = 1; i < tokens.length; i++)
		{
			bool isKwd = tokens[i - 1].match!((ref TokenKeyword t) => t.kind.isOneOf("ARRAY", "STRUCT"), (ref _) => false);
			auto op = tokens[i].match!((ref TokenOperator t) => t.text, (ref _) => null);
			if (isKwd && op == "<")
			{
				tokens[i] = Token(TokenAngleBracket("<"));
				depth++;
			}
			else
			if (depth && op == "<")
				throw new Exception("Ambiguous <");
			else
			if (depth && op == ">")
			{
				tokens[i] = Token(TokenAngleBracket(">"));
				depth--;
			}
			else
			if (depth && op == ">>")
			{
				enforce(depth >= 2, "Unclosed <");
				tokens = tokens[0 .. i] ~ Token(TokenAngleBracket(">")) ~ Token(TokenAngleBracket(">")) ~ tokens[i + 1 .. $];
				depth -= 2;
			}
		}
		enforce(depth == 0, "Unclosed <");
	}

	return tokens;
}

bool readDbtExpression(ref string s, ref DbtString text, QuotingContext quoting)
{
	if (s.skipOver("{{"))
	{
		// Perform basic lexing of Jinja syntax to find the end of the expression.
		string orig = s;
		while (s.length)
		{
			if (s.skipOver("}}"))
			{
				text ~= DbtStringElem(
					DbtExpression(
						orig[0 .. orig.length - s.length - "}}".length],
						quoting
					)
				);
				return true;
			}
			else
			if (s[0].among('\'', '"'))
			{
				auto quote = s[0 .. 1];
				s = s[1 .. $];
				s.skipUntil(quote).enforce("Unterminated string in Dbt expression");
			}
			else
				s = s[1 .. $]; // Skip other characters
		}
		throw new Exception("Unterminated Dbt expression");
	}
	return false;
}
