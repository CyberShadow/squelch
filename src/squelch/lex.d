module squelch.lex;

import std.algorithm.comparison;
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
	"&", "|",
	"=", "<>", "!=", "<=", ">=",
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

string[][] multiKeywords = [
	["CROSS", "JOIN"],
	["INNER", "JOIN"],
	["LEFT", "JOIN"],
	["LEFT", "OUTER", "JOIN"],
	["RIGHT", "JOIN"],
	["RIGHT", "OUTER", "JOIN"],
	["SELECT", "AS", "STRUCT"],
	["GROUP", "BY"],
	["ORDER", "BY"],
	["PARTITION", "BY"],
	["UNION", "ALL"],
	["UNION", "DISTINCT"],
	["INTERSECT", "DISTINCT"],
	["EXCEPT", "DISTINCT"],
];

Token[] lex(string s)
{
	Token[] tokens;
	scope(failure) stderr.writeln("Here: ", s[0 .. min(10, $)], (s.length > 10 ? "..." : ""));

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
			bool raw, bytes, triple;
			char quote;

			while (i < s.length)
			{
				if (toUpper(s[i]) == 'R')
				{
					raw = true;
					i++;
					continue;
				}
				if (toUpper(s[i]) == 'B')
				{
					bytes = true;
					i++;
					continue;
				}
				if (s[i].among('\'', '"', '`'))
				{
					s = s[i .. $];
					quote = s[0];
					if (s.length > 3 && s[1] == quote && s[2] == quote)
					{
						s = s[3 .. $];
						triple = true;
					}
					else
						s = s[1 .. $];

					// Parse string contents
					DbtString text;
					while (true)
					{
						enforce(s.length, "Unterminated string");
						if (s[0] == quote && (!triple || (s.length >= 3 && s[1] == quote && s[2] == quote)))
						{
							s = s[triple ? 3 : 1 .. $];
							if (quote == '`')
							{
								enforce(!raw && !bytes && !triple, "Invalid quoted identifier");
								tokens ~= Token(TokenIdentifier(text));
							}
							else
								tokens ~= Token(TokenString(text, bytes));
							continue tokenLoop;
						}

						if (s.readDbtExpression(text, QuotingContext(quote, raw, triple)))
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
			while (s.length)
			{
				if (s.readDbtExpression(text, QuotingContext(0)))
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
				tokens ~= Token(TokenOperator(operator));
				s = s[operator.length .. $];
				continue tokenLoop;
			}

		throw new Exception("Unrecognized syntax");
	}

	// Process contextual keywords

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

	// Join together keyword sequences which act as a single keyword
	foreach_reverse (i; 0 .. tokens.length)
	{
		alias kwdEquals = (Token a, string b) =>
			a.match!(
				(ref TokenKeyword t) => t.text == b,
				(ref _) => false,
			);
		foreach (multiKeyword; multiKeywords)
			if (tokens[i .. $].startsWith!kwdEquals(multiKeyword))
			{
				tokens = tokens[0 .. i] ~ Token(TokenKeyword(multiKeyword.join(" "))) ~ tokens[i + multiKeyword.length .. $];
				break;
			}
	}

	return tokens;
}

bool readDbtExpression(ref string s, ref DbtString text, QuotingContext quoting)
{
	if (s.skipOver("{{"))
	{
		text ~= DbtStringElem(
			DbtExpression(
				s.skipUntil("}}").enforce("Unterminated Dbt expression"),
				quoting
			)
		);
		return true;
	}
	return false;
}
