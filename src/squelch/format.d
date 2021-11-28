module squelch.format;

import std.algorithm.comparison;
import std.algorithm.iteration : map;
import std.algorithm.searching;
import std.array;
import std.exception;
import std.range;
import std.stdio : File;
import std.string;
import std.sumtype : match;

import ae.utils.array : elementIndex;
import ae.utils.math : maximize;

import squelch.common;

// Break lines in expressions with more than this many typical characters.
enum maxLineComplexity = 65;

// String to prepend to lines, once per indentation level.
enum indentation = "  ";

Token[] format(const scope Token[] tokens)
{
	/// Tree node.
	static struct Node
	{
		string type;
		int indent = 1;

		Node*[] children; /// If null, then this is a leaf

		/// Covered tokens.
		size_t start, end;
	}
	Node root = { indent : 0 };

	enum WhiteSpace
	{
		none,
		space,
		newLine,
		blankLine,
	}
	// whiteSpace[i] is what whitespace we should add before tokens[i]
	auto whiteSpace = new WhiteSpace[tokens.length + 1];

	// If true, the corresponding whiteSpace may be changed to newLine
	auto softLineBreak = new bool[tokens.length + 1];

	// First pass
	{
		Node*[] stack = [&root];
		bool wasWord;

		foreach (ref token; tokens)
		{
			WhiteSpace wsPre, wsPost;
			void delegate()[] post;
			bool isWord;

			size_t tokenIndex = tokens.elementIndex(token);

			void stackPush(string type, int indent = 1)
			{
				auto n = new Node;
				n.type = type;
				n.indent = indent;
				n.start = tokenIndex;

				stack[$-1].children ~= n;
				stack ~= n;
			}

			void stackPop()
			{
				stack[$-1].end = tokenIndex;
				stack = stack[0 .. $-1];
			}

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
					switch (t.kind)
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
							post ~= { stackPush("BETWEEN", 0); };
							goto case "AS";
						case "AND":
						case "OR":
							if (stack[$-1].type == "BETWEEN")
							{
								stackPop();
								goto case "AS";
							}
							wsPost = WhiteSpace.space;
							if (stack[$-1].type == "SELECT" || stack[$-1].type == "JOIN")
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
							if (stack[$-1].type == "WITH")
								stackPop();
							post ~= { stackPush("SELECT"); };
							break;
						case "FROM":
							if (stack[$-1].type == "EXTRACT(")
								return;
							goto case "WHERE";
						case "BY":
							if (stack[$-1].type == "OVER(" || stack.map!(n => n.type).endsWith(["OVER(", "BY"]) ||
								stack[$-1].type == "AS(" || stack.map!(n => n.type).endsWith(["AS(", "BY"]))
							{
								wsPre = wsPost = WhiteSpace.space;
								softLineBreak[tokenIndex] = softLineBreak[tokenIndex + 1] = true;
								if (stack[$-1].type == "BY")
									stackPop();
								post ~= { stackPush("BY"); };
								return;
							}
							goto case "WHERE";
						case "WHERE":
						case "HAVING":
						case "QUALIFY":
						case "WINDOW":
							wsPre = wsPost = WhiteSpace.newLine;
							while (stack[$-1].type == "JOIN")
								stackPop();
							if (stack[$-1].type == "SELECT")
								stackPop();
							post ~= { stackPush("SELECT"); };
							break;
						case "JOIN":
							wsPre = WhiteSpace.newLine;
							wsPost = WhiteSpace.space;
							while (stack[$-1].type == "JOIN")
								stackPop();
							post ~= { stackPush("JOIN"); };
							break;
						case "ON":
							wsPre = wsPost = WhiteSpace.newLine;
							post ~= { stackPush("JOIN"); };
							break;
						case "ROWS":
							wsPre = WhiteSpace.newLine;
							wsPost = WhiteSpace.space;
							while (stack[$-1].type == "JOIN")
								stackPop();
							if (stack[$-1].type.among("SELECT", "BY"))
								stackPop();
							post ~= { stackPush("SELECT"); };
							break;
						case "EXCEPT":
							if (tokenIndex && tokens[tokenIndex - 1] == Token(TokenOperator("*")))
								return;
							goto case;
						case "UNION":
						case "INTERSECT":
							wsPre = wsPost = WhiteSpace.newLine;
							while (stack[$-1].type == "JOIN")
								stackPop();
							if (stack[$-1].type == "SELECT")
								stackPop();
							stackPush("UNION", -1);
							post ~= { stackPop(); };
							break;
						case "WITH":
							wsPre = wsPost = WhiteSpace.newLine;
							post ~= { stackPush("WITH"); };
							break;
						case "CASE":
							wsPre = wsPost = WhiteSpace.newLine;
							post ~= { stackPush("CASE"); };
							break;
						case "WHEN":
						case "ELSE":
							wsPre = WhiteSpace.newLine;
							break;
						case "END":
							wsPre = WhiteSpace.newLine;
							if (stack[$-1].type == "CASE")
								stackPop();
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
									(ref const TokenKeyword t) { context = t.kind ~ "("; },
									(ref const _) {},
								);
							if (stack.length && context.among("JOIN(", "USING(") && stack[$-1].type == "JOIN")
								stackPop();
							post ~= { stackPush(context); };
							break;
						case ")":
							softLineBreak[tokenIndex] = true;
							while (stack.length && !stack[$-1].type.endsWith("("))
								stackPop();
							enforce(stack.length, "Mismatched )");
							stackPop();

							if (tokenIndex + 1 < tokens.length)
								tokens[tokenIndex + 1].match!(
									(ref const TokenOperator t) {},
									(ref const TokenNumber t) {},
									(ref const _) { wsPost = WhiteSpace.space; }
								);

							break;
						case "[":
							softLineBreak[tokenIndex + 1] = true;
							post ~= { stackPush("["); };
							break;
						case "]":
							softLineBreak[tokenIndex] = true;
							while (stack.length && stack[$-1].type != "[")
								stackPop();
							enforce(stack.length, "Mismatched ]");
							stackPop();
							break;
						case ",":
							if (stack[$-1].type == "<")
								wsPost = WhiteSpace.space;
							else
							if (stack[$-1].type == "SELECT")
								wsPost = WhiteSpace.newLine;
							else
							if (stack[$-1].type == "WITH")
								wsPost = WhiteSpace.blankLine;
							else
							{
								wsPost = WhiteSpace.space;
								softLineBreak[tokenIndex + 1] = true;
							}
							break;
						case ";":
							wsPost = WhiteSpace.blankLine;
							while (stack[$-1].type == "SELECT" || stack[$-1].type == "WITH" || stack[$-1].type == "JOIN")
								stackPop();
							break;
						case "*":
							if (tokenIndex && tokens[tokenIndex - 1].match!(
									(ref const TokenOperator t) => t.text == ".",
									(ref const _) => false
								))
							{
								wsPost = WhiteSpace.space;
								break;
							}
							if (tokenIndex + 1 < tokens.length && tokens[tokenIndex + 1].match!(
									(ref const TokenOperator t) => t.text == ",",
									(ref const _) => false
								))
							{
								wsPre = WhiteSpace.space;
								break;
							}
							goto default;
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
							post ~= { stackPush("<"); };
							break;
						case ">":
							while (stack.length && stack[$-1].type != "<")
								stackPop();
							enforce(stack.length, "Mismatched >");
							stackPop();
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
							post ~= { stackPush("%" ~ t.kind); };
							break;
						case "set":
							if (!t.text.canFind('='))
								post ~= { stackPush("%" ~ t.kind); };
							break;
						case "elif":
						case "else":
						{
							while (stack.length && !stack[$-1].type.startsWith("%")) stackPop();
							enforce(stack[$-1].type == "%if" || stack[$-1].type == "%for",
								"Found " ~ t.kind ~ " but expected " ~ (stack.length ? "end" ~ stack[$-1].type[1..$] : "end-of-file")
							);
							auto context = stack[$-1].type;
							stackPop();
							post ~= { stackPush(context); };
							break;
						}
						case "endfor":
						case "endif":
						case "endmacro":
						case "endfilter":
						case "endset":
							while (stack.length && !stack[$-1].type.startsWith("%")) stackPop();
							enforce(stack.map!(n => n.type).endsWith("%" ~ t.kind[3 .. $]),
								"Found " ~ t.kind ~ " but expected " ~ (stack.length ? "end" ~ stack[$-1].type[1..$] : "end-of-file")
							);
							stackPop();
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

			tokenIndex++;
			foreach (fun; post)
				fun();

			whiteSpace[tokenIndex] = wsPost;
			wasWord = isWord;
		}

		while (stack.length)
		{
			stack[$-1].end = tokens.length;
			stack = stack[0 .. $-1];
		}
	}

	size_t typicalLength(size_t tokenIndex)
	{
		return tokens[tokenIndex].match!(
			(ref const TokenWhiteSpace t) => 0,
			(ref const TokenComment t) => 60,
			(ref const TokenKeyword t) => t.text.split(" ").length * (5 + 1),
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

	// Convert nesting level into per-token indent level.
	auto indent = new int[tokens.length];
	{
		void scan(Node* node)
		{
			indent[node.start .. node.end] += node.indent;
			foreach (child; node.children)
				scan(child);
		}
		scan(&root);
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
					result ~= Token(TokenWhiteSpace("\n" ~ indentation.replicate(indent[i].max(0))));
					break;
			}
		}
		result ~= tokens[i];
	}

	if (tokens.length)
		result ~= Token(TokenWhiteSpace("\n"));

	return result;
}
