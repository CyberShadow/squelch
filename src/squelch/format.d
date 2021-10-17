module squelch.format;

import std.algorithm.comparison;
import std.algorithm.searching;
import std.array;
import std.exception;
import std.range;
import std.stdio : File;
import std.string;
import std.sumtype : match;

import squelch.common;

// Break lines in expressions with more than this many tokens.
enum breakComplexity = 8;

Token[] format(const scope Token[] tokens)
{
	enum WhiteSpace
	{
		none,
		space,
		softNewLine, // space or newLine depending on local complexity
		newLine,
		blankLine,
	}
	// whiteSpace[i] is what whitespace we should add before tokens[i]
	auto whiteSpace = new WhiteSpace[tokens.length + 1];
	auto indent = new size_t[tokens.length];

	// First pass
	{
		bool wasWord;
		string[] stack;

		foreach (tokenIndex, ref token; tokens)
		{
			WhiteSpace wsPre, wsPost;
			void delegate()[] post;
			bool isWord, outdent;

			token.match!(
				(ref const TokenWhiteSpace t)
				{
					assert(false);
				},
				(ref const TokenComment t)
				{
					wsPre = wsPost = WhiteSpace.newLine;
				},
				(ref const TokenKeyword t)
				{
					isWord = true;
					switch (t.text)
					{
						case "AS":
						case "AND":
						case "OR":
						case "NOT":
						case "LIKE":
						case "BETWEEN":
						case "IN":
						case "IS":
						case "OVER":
						case "THEN":
						case "RETURNS":
						case "IGNORE":
							wsPre = wsPost = WhiteSpace.space;
							break;
						case "SELECT":
						case "SELECT AS STRUCT":
							wsPre = wsPost = WhiteSpace.newLine;
							if (stack.endsWith("WITH"))
								stack.popBack();
							post ~= { stack ~= "SELECT"; };
							break;
						case "FROM":
							if (stack.endsWith("EXTRACT("))
								return;
							goto case;
						case "WHERE":
						case "JOIN":
						case "CROSS JOIN":
						case "INNER JOIN":
						case "LEFT JOIN":
						case "LEFT OUTER JOIN":
						case "RIGHT JOIN":
						case "RIGHT OUTER JOIN":
						case "GROUP BY":
						case "ORDER BY":
						case "HAVING":
						case "QUALIFY":
						case "PARTITION BY":
						case "WINDOW":
							wsPre = wsPost = WhiteSpace.newLine;
							if (stack.endsWith("SELECT"))
								stack.popBack();
							post ~= { stack ~= "SELECT"; };
							break;
						case "ROWS":
							wsPre = WhiteSpace.newLine;
							if (stack.endsWith("SELECT"))
								stack.popBack();
							post ~= { stack ~= "SELECT"; };
							break;
						case "UNION ALL":
						case "UNION DISTINCT":
						case "INTERSECT DISTINCT":
						case "EXCEPT DISTINCT":
							wsPre = wsPost = WhiteSpace.newLine;
							if (stack.endsWith("SELECT"))
								stack.popBack();
							outdent = true;
							break;
						case "WITH":
							wsPre = wsPost = WhiteSpace.newLine;
							post ~= { stack ~= "WITH"; };
							break;
						case "USING":
							wsPre = WhiteSpace.newLine;
							break;
						case "CASE":
							wsPre = wsPost = WhiteSpace.newLine;
							post ~= { stack ~= "CASE"; };
							break;
						case "WHEN":
						case "ELSE":
							wsPre = WhiteSpace.newLine;
							break;
						case "END":
							wsPre = WhiteSpace.newLine;
							if (stack.endsWith("CASE"))
								stack.popBack();
							break;
						default:
							break;
					}
				},
				(ref const TokenIdentifier t)
				{
					// If this is a Dbt call which we know doesn't produce any output,
					// format it like a statement.
					if (t.text.length == 1)
						t.text[0].match!(
							(ref const DbtExpression e)
							{
								string s = e.expr;
								s.skipOver("-");
								if (s.strip.startsWith("config("))
									wsPre = wsPost = WhiteSpace.blankLine;
							},
							(ref const _) {}
						);

					isWord = true;
				},
				(ref const TokenNamedParameter t)
				{
					isWord = true;
				},
				(ref const TokenOperator t)
				{
					switch (t.text)
					{
						case ".":
							break;
						case "(":
							wsPost = WhiteSpace.softNewLine;
							string context = "(";
							if (tokenIndex)
								tokens[tokenIndex - 1].match!(
									(ref const TokenIdentifier t) { context = '`' ~ t.text.tryToString() ~ "`("; },
									(ref const TokenKeyword t) { context = t.text ~ "("; },
									(ref const _) {},
								);
							post ~= { stack ~= context; };
							break;
						case ")":
							wsPre = WhiteSpace.softNewLine;
							stack = stack.retro.find!(s => s.endsWith("(")).retro;
							enforce(stack.length, "Mismatched )");
							stack = stack[0 .. $-1];
							break;
						case "[":
							wsPost = WhiteSpace.newLine;
							post ~= { stack ~= "["; };
							break;
						case "]":
							wsPre = WhiteSpace.newLine;
							stack = retro(find(retro(stack), "["));
							enforce(stack.length, "Mismatched ]");
							stack = stack[0 .. $-1];
							break;
						case ",":
							if (stack.endsWith("<"))
								wsPost = WhiteSpace.space;
							else
							if (stack.endsWith("SELECT"))
								wsPost = WhiteSpace.newLine;
							else
							if (stack.endsWith("WITH"))
								wsPost = WhiteSpace.blankLine;
							else
								wsPost = WhiteSpace.softNewLine;
							break;
						case ";":
							wsPost = WhiteSpace.blankLine;
							while (stack.endsWith("SELECT") || stack.endsWith("WITH"))
								stack.popBack();
							break;
						default:
							// Binary operators and others
							wsPre = wsPost = WhiteSpace.space;
							break;
					}
				},
				(ref const TokenAngleBracket t)
				{
					final switch (t.text)
					{
						case "<":
							post ~= { stack ~= "<"; };
							break;
						case ">":
							stack = retro(find(retro(stack), "<"));
							enforce(stack.length, "Mismatched >");
							stack = stack[0 .. $-1];
							break;
					}
				},
				(ref const TokenString t)
				{
					isWord = true;
				},
				(ref const TokenNumber t)
				{
					isWord = true;
				},
				(ref const TokenDbtStatement t)
				{
					wsPre = wsPost = WhiteSpace.newLine;
					switch (t.kind)
					{
						case "for":
						case "if":
						case "macro":
						case "filter":
							post ~= { stack ~= "%" ~ t.kind; };
							break;
						case "set":
							if (!t.text.canFind('='))
								post ~= { stack ~= "%" ~ t.kind; };
							break;
						case "elif":
						case "else":
							while (stack.length && !stack[$-1].startsWith("%")) stack.popBack();
							enforce(stack.endsWith("%if"),
								"Found " ~ t.kind ~ " but expected " ~ (stack.length ? "end" ~ stack[$-1][1..$] : "end-of-file")
							);
							stack.popBack();
							post ~= { stack ~= "%if"; };
							break;
						case "endfor":
						case "endif":
						case "endmacro":
						case "endfilter":
						case "endset":
							while (stack.length && !stack[$-1].startsWith("%")) stack.popBack();
							enforce(stack.endsWith("%" ~ t.kind[3 .. $]),
								"Found " ~ t.kind ~ " but expected " ~ (stack.length ? "end" ~ stack[$-1][1..$] : "end-of-file")
							);
							stack.popBack();
							break;
						default:
							break;
					}
				},
				(ref const TokenDbtComment t)
				{
					wsPre = wsPost = WhiteSpace.newLine;
				},
			);

			whiteSpace[tokenIndex] = max(whiteSpace[tokenIndex], wsPre);
			if (!whiteSpace[tokenIndex] && wasWord && isWord)
				whiteSpace[tokenIndex] = WhiteSpace.space;

			indent[tokenIndex] = stack.length;
			if (indent[tokenIndex] && outdent)
				indent[tokenIndex]--;

			foreach (fun; post)
				fun();

			whiteSpace[tokenIndex + 1] = wsPost;
			wasWord = isWord;
		}
	}

	// Second pass: add newlines for ( / ) / , tokens in complex expressions
	{
		// Calculate local complexity (token count) of paren groups.
		// We use this information later to decide whether commas and parens should break lines.
		auto complexity = new size_t[tokens.length];

		size_t[] stack;
		foreach (tokenIndex, ref token; tokens)
			token.match!(
				(ref const TokenOperator t)
				{
					switch (t.text)
					{
						case "(":
							stack ~= tokenIndex;
							break;

						case ")":
							enforce(stack.length, "Unmatched (");

							auto c = tokenIndex + 1 - stack[$-1];
							foreach (i; stack[$-1] .. tokenIndex)
								if (whiteSpace[i + 1] >= WhiteSpace.newLine)
									c = int.max; // Forced by e.g. sub-query

							foreach (i; stack[$-1] + 1 .. tokenIndex + 1)
								if (!complexity[i])
									complexity[i] = c;

							stack = stack[0 .. $-1];
							break;
						default:
					}
				},
				(ref const _) {}
			);

		foreach (tokenIndex; 0 .. tokens.length + 1)
			if (whiteSpace[tokenIndex] == WhiteSpace.softNewLine)
			{
				auto c = complexity[tokenIndex];
				whiteSpace[tokenIndex] = c < breakComplexity ? WhiteSpace.space : WhiteSpace.newLine;
			}
	}

	// Style tweak: remove space between ( and )
	foreach (i; 1 .. tokens.length)
		if (tokens[i - 1] == Token(TokenOperator("(")) &&
			tokens[i    ] == Token(TokenOperator(")")) &&
			whiteSpace[i] == WhiteSpace.space)
			whiteSpace[i] = WhiteSpace.none;

	// Comments generally describe the thing below them,
	// so should be aligned accordingly
	foreach_reverse (i; 1 .. tokens.length)
		tokens[i - 1].match!(
			(ref const TokenComment t) { indent[i - 1] = indent[i]; },
			(ref const _) {}
		);

	// Final pass: materialize WhiteSpace into TokenWhiteSpace
	Token[] result;
	foreach (i; 0 .. tokens.length)
	{
		if (i && whiteSpace[i])
		{
			final switch (whiteSpace[i])
			{
				case WhiteSpace.none:
					break;
				case WhiteSpace.space:
					result ~= Token(TokenWhiteSpace(" "));
					break;
				case WhiteSpace.softNewLine:
					assert(false);
				case WhiteSpace.blankLine:
					result ~= Token(TokenWhiteSpace("\n"));
					goto case;
				case WhiteSpace.newLine:
					result ~= Token(TokenWhiteSpace("\n" ~ "\t".replicate(indent[i])));
					break;
			}
		}
		result ~= tokens[i];
	}

	if (tokens.length)
		result ~= Token(TokenWhiteSpace("\n"));

	return result;
}
