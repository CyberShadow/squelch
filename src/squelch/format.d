module squelch.format;

import std.algorithm.comparison : among, max;
import std.algorithm.iteration : map;
import std.algorithm.searching;
import std.array : replicate, split;
import std.exception;
import std.range : retro;
import std.string : strip;
import std.sumtype : match;

static import std.string;

import ae.utils.array : elementIndex;
import ae.utils.math : maximize;

import squelch.common;

// Break lines in expressions with more than this many typical characters.
enum maxLineComplexity = 65;

// String to prepend to lines, once per indentation level.
enum indentation = "  ";

Token[] format(const scope Token[] tokens)
{
	// Lexical priorities
	enum Level
	{
		// https://cloud.google.com/bigquery/docs/reference/standard-sql/operators
		parensOuter, /// function call, subscript
		// unary,
		// Binary operators - highest priority:
		multiplication,
		addition,
		shift,
		bitwiseAnd,
		bitwiseXor,
		bitwiseOr,
		comparison,
		// not,
		and,
		or,

		then,
		when,
		case_,

		// Technically not a binary operator, but acts like a low-priority one
		comma,

		// Things like SELECT go here
		with_,
		on,
		join,
		select,
		union_,
		statement = union_,

		// A closing paren unambiguously terminates all other lexical constructs
		parensInner,

		// Dbt macros form their own independent hierarchy
		dbt,

		// Lowest priority - terminates all constructs
		file,
	}

	/// Tree node.
	static struct Node
	{
		Level level; /// Nesting / priority level of this node's expression
		string type; /// A string identifying the specific operation
		string prevType; /// The previous operation at the same level, when they are consecutive

		Node*[] children; /// If null, then this is a leaf

		/// Covered tokens.
		size_t start, end;

		/// Default indentation level.
		byte indent = 1;

		/// Complexity bias, to allow matching complexity of some nested structures.
		int complexityBias = 0;

		/// Indentation level overrides for specific tokens
		/// (mainly for tokens are part of this node's syntax,
		/// and should not be indented).
		byte[size_t] tokenIndent;

		// If true, the corresponding whiteSpace may be changed to newLine
		bool[size_t] softLineBreak;
	}
	Node root = {
		level : Level.file,
		type : "file",
		indent : false,
	};

	enum WhiteSpace
	{
		none,
		space,
		newLine,
		blankLine,
	}
	// whiteSpace[i] is what whitespace we should add before tokens[i]
	auto whiteSpace = new WhiteSpace[tokens.length + 1];

	// First pass
	{
		Node*[] stack = [&root];
		bool wasWord;

		foreach (ref token; tokens)
		{
			WhiteSpace wsPre, wsPost;
			bool isWord;

			size_t tokenIndex = tokens.elementIndex(token);

			Node* stackPush_(Level level, string type)
			{
				auto n = new Node;
				n.level = level;
				n.type = type;
				n.start = tokenIndex;

				stack[$-1].children ~= n;
				stack ~= n;
				return n;
			}

			Node* stackPop_(bool afterCurrent)
			{
				auto n = stack[$-1];
				n.end = tokenIndex + afterCurrent;
				stack = stack[0 .. $-1];
				return n;
			}

			void stackPopTo(Level level)
			{
				while (stack[$-1].level < level)
					stackPop_(false);
			}

			Node* stackEnter(Level level, string type, bool glueBackwards = false)
			{
				stackPopTo(level);

				if (stack[$-1].level == level)
				{
					if (glueBackwards)
					{
						stack[$-1].prevType = stack[$-1].type;
						stack[$-1].type = type;
						return stack[$-1];
					}
					else
						stackPop_(false);
				}

				return stackPush_(level, type);
			}


			Node* stackExit(Level level, string expected)
			{
				stackPopTo(level);
				enforce(stack[$-1].level == level, std.string.format!
					"Found end of %s while looking for end of %s"(
					stack[$-1].type, expected));
				return stackPop_(true);
			}

			// Like stackEnter, but adopts previous nodes that have a higher priority.
			// Suitable for binary operators.
			Node* stackInsert(Level level, string type)
			{
				stackPopTo(level);

				if (stack[$-1].level == level)
				{
					// Implicitly glue backwards
					stack[$-1].prevType = stack[$-1].type;
					stack[$-1].type = type;
				}
				else
				{
					auto p = stack[$-1];
					Node*[] children;

					// Move the previous hierarchy into the new inserted level
					{
						auto i = p.children.length;
						while (i && p.children[i-1].level < level)
							i--;
						children = p.children[i .. $];
						p.children = p.children[0 .. i];
					}

					auto n = stackPush_(level, type);
					n.children = children;
					n.start = children.length ? children[0].start : tokenIndex;

					// Extend the start backwards to adopt non-syntax tokens
					auto limit = p.children.length > 1 ? p.children[$-2].end : p.start;
					while (n.start > limit && (n.start - 1) !in p.tokenIndent && (n.start) !in p.softLineBreak)
						n.start--;
				}
				return stack[$-1];
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
						case "RETURNS":
						case "IGNORE":
						case "USING":
							wsPre = wsPost = WhiteSpace.space;
							break;
						case "BETWEEN":
							stackInsert(Level.comparison, "BETWEEN");
							goto case "AS";
						case "AND":
						case "OR":
							wsPre = wsPost = WhiteSpace.space;
							auto n = stackInsert(Level.comparison, t.kind);
							n.indent = 0;
							if (n.prevType == "BETWEEN")
							{
								n.tokenIndent[tokenIndex] = 0;
								break;
							}
							if (stack[$-2].level == Level.select || stack[$-2].level == Level.on)
								wsPre = WhiteSpace.newLine;
							else
								wsPre = WhiteSpace.space;
							return;

						case "SELECT":
							wsPre = wsPost = WhiteSpace.newLine;
							auto n = stackEnter(Level.select, t.text);
							n.tokenIndent[tokenIndex] = 0;
							break;
						case "FROM":
							if (stack[$-1].type == "EXTRACT(")
								return;
							goto case "WHERE";
						case "BY":
							if (stack
								.retro
								.find!(n => n.level >= Level.parensInner)
								.front
								.type
								.among("OVER(", "AS("))
							{
								wsPre = wsPost = WhiteSpace.space;
								auto n = stackEnter(Level.select, "BY-inline", true);
								n.tokenIndent[tokenIndex] = 0;
								n.softLineBreak[tokenIndex] = n.softLineBreak[tokenIndex + 1] = true;
								return;
							}
							goto case "WHERE";
						case "WHERE":
						case "HAVING":
						case "QUALIFY":
						case "WINDOW":
							wsPre = wsPost = WhiteSpace.newLine;
							auto n = stackEnter(Level.select, t.text);
							n.tokenIndent[tokenIndex] = 0;
							break;
						case "JOIN":
							wsPre = WhiteSpace.newLine;
							wsPost = WhiteSpace.space;
							stackPopTo(Level.join);
							auto n = stackEnter(Level.join, t.kind);
							n.tokenIndent[tokenIndex] = 0;
							break;
						case "ON":
							wsPre = wsPost = WhiteSpace.newLine;
							auto n = stackEnter(Level.on, t.kind);
							n.tokenIndent[tokenIndex] = 0;
							break;
						case "ROWS":
							wsPre = WhiteSpace.newLine;
							wsPost = WhiteSpace.space;
							auto n = stackEnter(Level.select, t.kind, true);
							n.tokenIndent[tokenIndex] = 0;
							n.softLineBreak[tokenIndex] = true;
							break;
						case "EXCEPT":
							if (tokenIndex && tokens[tokenIndex - 1] == Token(TokenOperator("*")))
								return;
							goto case;
						case "UNION":
						case "INTERSECT":
							wsPre = wsPost = WhiteSpace.newLine;
							auto n = stackEnter(Level.union_, t.text);
							n.indent = 0;
							n.tokenIndent[tokenIndex] = -1;
							break;
						case "WITH":
							wsPre = wsPost = WhiteSpace.newLine;
							auto n = stackEnter(Level.select, t.text);
							n.tokenIndent[tokenIndex] = 0;
							break;
						case "CREATE":
							wsPre = WhiteSpace.newLine;
							auto n = stackEnter(Level.select, t.text);
							n.indent = 0;
							n.tokenIndent[tokenIndex] = 0;
							break;
						case "CASE":
							wsPre = wsPost = WhiteSpace.newLine;
							auto n = stackEnter(Level.case_, t.text);
							n.tokenIndent[tokenIndex] = 0;
							break;
						case "WHEN":
						case "ELSE":
							wsPre = WhiteSpace.newLine;
							auto n = stackEnter(Level.when, t.text);
							n.indent = 0;
							n.tokenIndent[tokenIndex] = 0;
							break;
						case "THEN":
							wsPre = wsPost = WhiteSpace.space;
							auto n = stackEnter(Level.then, t.text);
							n.tokenIndent[tokenIndex] = 0;
							n.softLineBreak[tokenIndex] = true;
							break;
						case "END":
							wsPre = WhiteSpace.newLine;
							auto n = stackExit(Level.case_, "CASE ... END");
							n.tokenIndent[tokenIndex] = 0;
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
							string context = "(";
							if (tokenIndex)
								tokens[tokenIndex - 1].match!(
									(ref const TokenIdentifier t) { context = '`' ~ t.text.tryToString() ~ "`("; },
									(ref const TokenKeyword t) { context = t.kind ~ "("; },
									(ref const _) {},
								);
							if (context.among("JOIN(", "USING(") && stack[$-1].type == "JOIN")
								stack[$-1].indent = 0;
							auto n = stackInsert(Level.parensOuter, context);
							n.indent = n.tokenIndent[tokenIndex] = 0;
							n = stackPush_(Level.parensInner, context);
							n.tokenIndent[tokenIndex] = 0;
							n.softLineBreak[tokenIndex + 1] = true;
							break;
						case ")":
							auto n = stackExit(Level.parensInner, "( ... )");
							enforce(n.type.endsWith("("), "Found end of " ~ n.type ~ " while looking for end of ( ... )");
							n.tokenIndent[tokenIndex] = 0;
							n.softLineBreak[tokenIndex] = true;
							stackExit(Level.parensOuter, "( ... )");

							if (tokenIndex + 1 < tokens.length)
								tokens[tokenIndex + 1].match!(
									(ref const TokenOperator t) {},
									(ref const TokenNumber t) {},
									(ref const _) { wsPost = WhiteSpace.space; }
								);

							break;
						case "[":
							auto n = stackInsert(Level.parensOuter, t.text);
							n.indent = n.tokenIndent[tokenIndex] = 0;
							n = stackPush_(Level.parensInner, t.text);
							n.tokenIndent[tokenIndex] = 0;
							n.softLineBreak[tokenIndex + 1] = true;
							break;
						case "]":
							auto n = stackExit(Level.parensInner, "[ ... ]");
							enforce(n.type == "[", "Found end of " ~ n.type ~ " while looking for end of [ ... ]");
							n.tokenIndent[tokenIndex] = 0;
							n.softLineBreak[tokenIndex] = true;
							stackExit(Level.parensOuter, "[ ... ]");
							break;
						case ",":
							auto n = stackInsert(Level.comma, t.text);
							n.indent = 0;
							n.tokenIndent[tokenIndex] = 0;
							n.complexityBias = 2; // Match complexity of parens

							if (stack[$-2].type == "<")
								wsPost = WhiteSpace.space;
							else
							if (stack[$-2].type == "WITH")
								wsPost = WhiteSpace.blankLine;
							else
							if (stack[$-2].level == Level.select && stack[$-2].type != "BY-inline")
								wsPost = WhiteSpace.newLine;
							else
							{
								wsPost = WhiteSpace.space;
								n.softLineBreak[tokenIndex + 1] = true;
							}
							break;
						case ";":
							wsPost = WhiteSpace.blankLine;
							auto n = stackInsert(Level.statement, t.text);
							n.indent = 0;
							n.tokenIndent[tokenIndex] = 0;
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
							auto n = stackInsert(Level.parensOuter, t.text);
							n.indent = n.tokenIndent[tokenIndex] = 0;
							n = stackPush_(Level.parensInner, t.text);
							n.tokenIndent[tokenIndex] = 0;
							break;
						case ">":
							auto n = stackExit(Level.parensInner, "< ... >");
							enforce(n.type == "<", "Found end of " ~ n.type ~ " while looking for end of < ... >");
							n.tokenIndent[tokenIndex] = 0;
							stackExit(Level.parensOuter, "< ... >");
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
							auto n = stackPush_(Level.dbt, "%" ~ t.kind);
							n.tokenIndent[tokenIndex] = 0;
							break;
						case "set":
							if (!t.text.canFind('='))
								goto case "for";
							break;
						case "elif":
						case "else":
							auto i = stack.countUntil!(n => n.level == Level.dbt);
							enforce(i >= 0, "Mismatched " ~ t.kind);
							enforce(stack[i].type == "%if" || stack[i].type == "%for",
								"Found " ~ t.kind ~ " but expected end" ~ stack[i].type[1..$]
							);
							stack[i].tokenIndent[tokenIndex] = 0;
							break;
						case "endfor":
						case "endif":
						case "endmacro":
						case "endfilter":
						case "endset":
							auto i = stack.countUntil!(n => n.level == Level.dbt);
							enforce(i >= 0, "Mismatched " ~ t.kind);
							enforce(stack[i].type.endsWith("%" ~ t.kind[3 .. $]),
								"Found " ~ t.kind ~ " but expected end" ~ stack[i].type[1..$]
							);
							stack[i].tokenIndent[tokenIndex] = 0;
							stack[i].end = tokenIndex + 1;
							stack = stack[0 .. i] ~ stack[i + 1 .. $];
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

	// Convert nested hierarchy into flattened whitespace.
	auto indent = new int[tokens.length];
	{
		int currentIndent;
		size_t i = 0;

		int scan(Node* n)
		in (i == n.start)
		out(; i == n.end)
		{
			int complexity = n.complexityBias;

			foreach (childIndex; 0 .. n.children.length + 1)
			{
				// Process the gap before this child
				// auto gapStart = i;
				auto gapEnd = childIndex < n.children.length ? n.children[childIndex].start : n.end;
				while (true)
				{
					if (i < gapEnd)
					{
						indent[i] = currentIndent + n.indent;

						complexity += typicalLength(i);
					}

					// A newline belongs to the inner-most node which fully contains it
					if (i > n.start && i < n.end)
						if (whiteSpace[i] >= WhiteSpace.newLine)
							complexity = maxLineComplexity;  // Forced by e.g. sub-query

					if (i < gapEnd)
						i++;
					else
						break;
				}

				// Process the child
				if (childIndex < n.children.length)
				{
					currentIndent += n.indent;
					scope(success) currentIndent -= n.indent;

					complexity += scan(n.children[childIndex]);
				}
			}

			// Apply per-token indents at this level
			foreach (tokenIndex, tokenIndent; n.tokenIndent)
				indent[tokenIndex] += tokenIndent - n.indent;

			if (complexity >= maxLineComplexity)
			{
				// Do a second pass, converting soft line breaks to hard
				foreach (i, _; n.softLineBreak)
					whiteSpace[i].maximize(WhiteSpace.newLine);
			}

			return complexity;
		}
		scan(&root);

		assert(currentIndent == 0);
		assert(i == tokens.length);
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
		if (i)
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
		else
			result ~= Token(TokenWhiteSpace(indentation.replicate(indent[i].max(0)))); // Pedantic - should always be 0
		result ~= tokens[i];
	}

	if (tokens.length)
		result ~= Token(TokenWhiteSpace("\n"));

	return result;
}
