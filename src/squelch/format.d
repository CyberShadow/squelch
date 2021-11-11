module squelch.format;

import std.algorithm.comparison;
import std.algorithm.searching;
import std.array;
import std.exception;
import std.range;
import std.stdio : File;
import std.string;
import std.sumtype : match;

import ae.utils.math : maximize;

import squelch.common;

// Break lines in expressions with more than this many typical characters.
enum maxLineComplexity = 65;

// String to prepend to lines, once per indentation level.
enum indentation = "  ";

Token[] format(const scope Token[] tokens)
{
	enum WhiteSpace
	{
		none,
		space,
		newLine,
		blankLine,
	}
	// whiteSpace[i] is what whitespace we should add before tokens[i]
	auto whiteSpace = new WhiteSpace[tokens.length + 1];
	auto indent = new size_t[tokens.length];

	// If true, the corresponding whiteSpace may be changed to newLine
	auto softLineBreak = new bool[tokens.length + 1];

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
						case "NOT":
						case "LIKE":
						case "IN":
						case "IS":
						case "OVER":
						case "THEN":
						case "RETURNS":
						case "IGNORE":
						case "USING":
							wsPre = wsPost = WhiteSpace.space;
							break;
						case "BETWEEN":
							post ~= { stack ~= "-BETWEEN"; };
							goto case "AS";
						case "AND":
						case "OR":
							if (stack.endsWith("-BETWEEN"))
							{
								stack.popBack();
								goto case "AS";
							}
							wsPost = WhiteSpace.space;
							if (stack.endsWith("SELECT") || stack.endsWith("JOIN"))
								wsPre = WhiteSpace.newLine;
							else
							// if (stack.length && stack[$-1].endsWith("("))
							// {
							// 	wsPre = wsPost = WhiteSpace.softNewLine;
							// 	outdent = true;
							// }
							// else
								wsPre = WhiteSpace.space;
							return;

						case "SELECT":
							wsPre = wsPost = WhiteSpace.newLine;
							if (stack.endsWith("WITH"))
								stack.popBack();
							post ~= { stack ~= "SELECT"; };
							break;
						case "FROM":
							if (stack.endsWith("EXTRACT("))
								return;
							goto case "WHERE";
						case "BY":
							if (stack.endsWith("OVER(") || stack.endsWith(["OVER(", "SELECT"]) ||
								stack.endsWith("AS(") || stack.endsWith(["AS(", "SELECT"]))
							{
								wsPre = wsPost = WhiteSpace.space;
								softLineBreak[tokenIndex] = softLineBreak[tokenIndex + 1] = true;
								if (stack.endsWith("SELECT"))
									stack.popBack();
								post ~= { stack ~= "SELECT"; };
								return;
							}
							goto case "WHERE";
						case "WHERE":
						case "HAVING":
						case "QUALIFY":
						case "WINDOW":
							wsPre = wsPost = WhiteSpace.newLine;
							while (stack.endsWith("JOIN"))
								stack.popBack();
							if (stack.endsWith("SELECT"))
								stack.popBack();
							post ~= { stack ~= "SELECT"; };
							break;
						case "JOIN":
							wsPre = WhiteSpace.newLine;
							wsPost = WhiteSpace.space;
							while (stack.endsWith("JOIN"))
								stack.popBack();
							post ~= { stack ~= "JOIN"; };
							break;
						case "ON":
							wsPre = wsPost = WhiteSpace.newLine;
							post ~= { stack ~= "JOIN"; };
							break;
						case "ROWS":
							wsPre = WhiteSpace.newLine;
							wsPost = WhiteSpace.space;
							while (stack.endsWith("JOIN"))
								stack.popBack();
							if (stack.endsWith("SELECT"))
								stack.popBack();
							post ~= { stack ~= "SELECT"; };
							break;
						case "EXCEPT":
							if (tokenIndex && tokens[tokenIndex - 1] == Token(TokenOperator("*")))
								return;
							goto case;
						case "UNION":
						case "INTERSECT":
							wsPre = wsPost = WhiteSpace.newLine;
							while (stack.endsWith("JOIN"))
								stack.popBack();
							if (stack.endsWith("SELECT"))
								stack.popBack();
							outdent = true;
							break;
						case "WITH":
							wsPre = wsPost = WhiteSpace.newLine;
							post ~= { stack ~= "WITH"; };
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
							softLineBreak[tokenIndex + 1] = true;
							string context = "(";
							if (tokenIndex)
								tokens[tokenIndex - 1].match!(
									(ref const TokenIdentifier t) { context = '`' ~ t.text.tryToString() ~ "`("; },
									(ref const TokenKeyword t) { context = t.text ~ "("; },
									(ref const _) {},
								);
							if (stack.length && context.among("JOIN(", "USING(") && stack[$-1] == "JOIN")
								stack = stack[0 .. $-1];
							post ~= { stack ~= context; };
							break;
						case ")":
							softLineBreak[tokenIndex] = true;
							stack = stack.retro.find!(s => s.endsWith("(")).retro;
							enforce(stack.length, "Mismatched )");
							stack = stack[0 .. $-1];

							if (tokenIndex + 1 < tokens.length)
								tokens[tokenIndex + 1].match!(
									(ref const TokenOperator t) {},
									(ref const TokenNumber t) {},
									(ref const _) { wsPost = WhiteSpace.space; }
								);

							break;
						case "[":
							softLineBreak[tokenIndex + 1] = true;
							post ~= { stack ~= "["; };
							break;
						case "]":
							softLineBreak[tokenIndex] = true;
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
							{
								wsPost = WhiteSpace.space;
								softLineBreak[tokenIndex + 1] = true;
							}
							break;
						case ";":
							wsPost = WhiteSpace.blankLine;
							while (stack.endsWith("SELECT") || stack.endsWith("WITH") || stack.endsWith("JOIN"))
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

			indent[tokenIndex] = stack.count!(e => !e.startsWith("-"));
			if (indent[tokenIndex] && outdent)
				indent[tokenIndex]--;

			foreach (fun; post)
				fun();

			whiteSpace[tokenIndex + 1] = wsPost;
			wasWord = isWord;
		}
	}

	// Massage whitespace for keyword sequences which act like one keyword (e.g. "ORDER BY")
	{
		void scan(bool forward, string[] headKwds, string[] tailKwds)
		{
			bool active;
			for (size_t tokenIndex = forward ? 0 : tokens.length - 1;
				 tokenIndex < tokens.length;
				 tokenIndex += forward ? +1 : -1)
			{
				auto kwd = tokens[tokenIndex].match!(
					(ref const TokenKeyword t) => t.text,
					(ref const _) => null,
				);

				if (headKwds.canFind(kwd))
					active = true;
				else
				if (active && tailKwds.canFind(kwd))
				{
					auto tokenIndexCurr = tokenIndex;
					auto tokenIndexPrev = tokenIndex + (forward ? -1 : +1);
					auto wsIndexCurr = tokenIndex + (forward ? +1 : 0);
					auto wsIndexPrev = tokenIndex + (forward ? 0 : +1);

					if (whiteSpace[wsIndexPrev] >= WhiteSpace.newLine)
						whiteSpace[wsIndexCurr].maximize(whiteSpace[wsIndexPrev]);
					whiteSpace[wsIndexPrev] = WhiteSpace.space;
					softLineBreak[wsIndexCurr].maximize(softLineBreak[wsIndexPrev]);
					softLineBreak[wsIndexPrev] = false;
					indent[tokenIndexCurr] = indent[tokenIndexPrev];
				}
				else
					active = false;
			}
		}

		scan(true, ["SELECT"], ["DISTINCT", "AS"]);
		scan(true, ["AS"], ["STRUCT"]);
		scan(true, ["UNION", "INTERSECT", "EXCEPT"], ["ALL", "DISTINCT"]);
		scan(true, ["IS"], ["NOT", "NULL", "TRUE", "FALSE"]);
		scan(true, ["CREATE"], ["OR", "REPLACE"]);

		scan(false, ["BY"], ["GROUP", "ORDER", "PARTITION"]);
		scan(false, ["JOIN"], ["FULL", "CROSS", "LEFT", "RIGHT", "INNER", "OUTER"]);
		scan(false, ["LIKE", "BETWEEN", "IN"], ["NOT"]);
	}

	size_t typicalLength(size_t tokenIndex)
	{
		return tokens[tokenIndex].match!(
			(ref const TokenWhiteSpace t) => 0,
			(ref const TokenComment t) => 60,
			(ref const TokenKeyword t) => 5 + 1,
			(ref const TokenIdentifier t) => t.text.count!(
				e => e.match!(
					(dchar c) => c == '_',
					(ref _) => false,
				)
			) * (5 + 1) + 5,
			(ref const TokenNamedParameter t) => 10,
			(ref const TokenOperator t) => 1 + 1,
			(ref const TokenAngleBracket t) => 1 + 1,
			(ref const TokenString t) => 10,
			(ref const TokenNumber t) => 3 + 1,
			(ref const TokenDbtStatement t) => 50,
			(ref const TokenDbtComment t) => 100,
		);
	}

	// Convert soft breaks into spaces or newlines, depending on local complexity
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
						case "[":
							stack ~= tokenIndex;
							break;

						case ")":
						case "]":
							enforce(stack.length, "Unmatched ( / [");

							int c;
							foreach (i; stack[$-1] .. tokenIndex + 1)
								c += typicalLength(i);
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
			if (softLineBreak[tokenIndex])
			{
				auto c = complexity[tokenIndex];
				if (c >= maxLineComplexity)
					whiteSpace[tokenIndex] = WhiteSpace.newLine;
			}
	}

	// Style tweak: remove space on the inside of ( and )
	foreach (i; 0 .. tokens.length)
	{
		if (tokens[i].among(Token(TokenOperator("(")), Token(TokenOperator("["))) && whiteSpace[i + 1] == WhiteSpace.space)
			whiteSpace[i + 1] = WhiteSpace.none;
		if (tokens[i].among(Token(TokenOperator(")")), Token(TokenOperator("]"))) && whiteSpace[i] == WhiteSpace.space)
			whiteSpace[i] = WhiteSpace.none;
	}

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
				case WhiteSpace.blankLine:
					result ~= Token(TokenWhiteSpace("\n"));
					goto case;
				case WhiteSpace.newLine:
					result ~= Token(TokenWhiteSpace("\n" ~ indentation.replicate(indent[i])));
					break;
			}
		}
		result ~= tokens[i];
	}

	if (tokens.length)
		result ~= Token(TokenWhiteSpace("\n"));

	return result;
}
