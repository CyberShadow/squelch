module squelch.format;

import std.algorithm.comparison : among, max;
import std.algorithm.iteration : map, filter, each;
import std.algorithm.searching;
import std.array : replicate, split;
import std.exception;
import std.range : retro;
import std.string : strip;
import std.sumtype : match;

static import std.string;

import ae.utils.array : elementIndex;
import ae.utils.math : maximize, minimize;

import squelch.common;

// Break lines in expressions with more than this many typical characters.
enum maxLineComplexity = 80;

// Indentation depth (number of spaces) to use for most constructs.
enum indentationWidth = 2;

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

		as,

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

		Node*[] children; /// If null, then this is a leaf

		/// Covered tokens.
		size_t start, end;

		/// Default indentation level.
		sizediff_t indent = indentationWidth;

		/// Don't indent unless this node contains line breaks
		bool conditionalIndent;

		/// If true, and the parent has its soft line breaks applied, do so here too
		bool breakWithParent;

		/// If true, and any sibling has its soft line breaks applied, do so here too
		bool breakWithSibling;

		/// Indentation level overrides for specific tokens
		/// (mainly for tokens are part of this node's syntax,
		/// and should not be indented).
		sizediff_t[size_t] tokenIndent;

		/// If set, overrides the parent's .indent for this node.
		int parentIndentOverride = int.min;

		/// If true, the corresponding whiteSpace may be changed to newLine
		bool[size_t] softLineBreak;

		/// State flag for newline application.
		bool breaksApplied;
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

			Node* stackPopTo(Level level)
			{
				while (stack[$-1].level < level)
					stackPop_(false);
				return stack[$-1].level == level ? stack[$-1] : null;
			}

			Node* stackEnter(Level level, string type, bool glueBackwards = false)
			{
				stackPopTo(level);

				if (stack[$-1].level == level)
				{
					if (glueBackwards)
					{
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
					stack[$-1].type = type;
				}
				else
				{
					auto p = stack[$-1];
					auto start = tokenIndex;
					auto childrenStart = p.children.length;

					// Extend the start backwards to adopt non-syntax tokens
					// and adopt higher-priority nodes
					while (start > p.start)
					{
						if (childrenStart && p.children[childrenStart - 1].end == start)
						{
							// Decide if we want to adopt this child
							if (p.children[childrenStart - 1].level < level)
							{
								childrenStart--;
								start = p.children[childrenStart].start;
							}
							else
								break;
						}
						else
						{
							// Extend the start backwards to adopt non-syntax tokens
							if ((start - 1) !in p.tokenIndent && (start) !in p.softLineBreak)
								start--;
							else
								break;
						}
					}

					// Move the previous hierarchy into the new inserted level
					Node*[] children = p.children[childrenStart .. $];
					p.children = p.children[0 .. childrenStart];

					auto n = stackPush_(level, type);
					n.children = children;
					n.start = start;
				}
				return stack[$-1];
			}

			// Common routine for creating nodes for binary operators
			Node* stackInsertBinary(Level level, string type)
			{
				wsPre = wsPost = WhiteSpace.space;
				auto n = stackInsert(level, type);
				n.indent.maximize(type.length + 1);
				n.tokenIndent[tokenIndex] = 0;
				n.conditionalIndent = true;
				n.softLineBreak[tokenIndex] = n.softLineBreak[n.start] = true;
				return n;
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
							wsPre = wsPost = WhiteSpace.space;
							if (tokenIndex + 1 < tokens.length
								&& tokens[tokenIndex + 1].match!(
									(ref const TokenIdentifier t) => true,
									(ref const _) => false
								)
								&& stack.retro
								.find!(n => n.level >= Level.select)
								.front
								.level == Level.select
								&& tokenIndex > 0
								&& !tokens[tokenIndex - 1].match!(
									(ref const TokenKeyword t) => t.kind == "WITH OFFSET",
									(ref const _) => false
								)
							)
								stackInsertBinary(Level.as, t.kind);
							break;
						case "NOT":
						case "IS":
						case "OVER":
						case "RETURNS":
						case "IGNORE":
						case "USING":
							wsPre = wsPost = WhiteSpace.space;
							break;
						case "BETWEEN":
							auto n = stackInsertBinary(Level.comparison, t.kind);
							n.softLineBreak.remove(tokenIndex);
							n.softLineBreak.remove(n.start);
							break;
						case "LIKE":
						case "IN":
							stackInsertBinary(Level.comparison, t.kind);
							break;
						case "AND":
							wsPre = wsPost = WhiteSpace.space;
							stackPopTo(Level.comparison);
							if (stack[$-1].type == "BETWEEN")
							{
								auto n = stackInsert(Level.comparison, t.kind);
								n.indent = 0;
								n.tokenIndent[tokenIndex] = 0;
								break;
							}
							stackInsertBinary(Level.and, t.kind);
							return;
						case "OR":
							stackInsertBinary(Level.or, t.kind);
							break;
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
								.among("OVER(", "AS(", "`ARRAY_AGG`("))
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
							n.tokenIndent[tokenIndex] = -indentationWidth;
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
							wsPre = wsPost = WhiteSpace.space;
							auto n = stackEnter(Level.case_, t.text);
							n.softLineBreak[tokenIndex] = n.softLineBreak[tokenIndex + 1] = true;
							n.tokenIndent[tokenIndex] = 0;
							break;
						case "WHEN":
						case "ELSE":
							wsPre = wsPost = WhiteSpace.space;
							auto p = stackPopTo(Level.case_);
							if (p)
								p.softLineBreak[tokenIndex] = true;
							auto n = stackEnter(Level.when, t.text);
							n.softLineBreak[tokenIndex] = true;
							n.indent = 2 * indentationWidth;
							n.tokenIndent[tokenIndex] = 0;
							n.breakWithSibling = true;
							break;
						case "THEN":
							wsPre = wsPost = WhiteSpace.space;
							auto n = stackEnter(Level.when, t.text, true);
							n.indent = 2 * indentationWidth;
							n.softLineBreak[tokenIndex] = true;
							n.tokenIndent[tokenIndex] = indentationWidth;
							break;
						case "END":
							wsPre = WhiteSpace.space;
							auto n = stackExit(Level.case_, "CASE ... END");
							n.softLineBreak[tokenIndex] = true;
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
							auto n = stackInsert(Level.parensOuter, context);
							n.indent = n.tokenIndent[tokenIndex] = 0;
							if (context.among("JOIN(", "USING(") && stack[$-2].type == "JOIN")
								n.parentIndentOverride = 0;
							if (context == "IN(")
								n.parentIndentOverride = 0;
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
							n.breakWithParent = true;

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
							goto case "/";

						// Binary operators and others
						case "=":
						case "<":
						case ">":
						case "<=":
						case ">=":
						case "!=":
						case "<>":
							stackInsertBinary(Level.comparison, t.text);
							break;
						case "|":
							stackInsertBinary(Level.bitwiseOr, t.text);
							break;
						case "^":
							stackInsertBinary(Level.bitwiseXor, t.text);
							break;
						case "&":
							stackInsertBinary(Level.bitwiseAnd, t.text);
							break;
						case "<<":
						case ">>":
							stackInsertBinary(Level.shift, t.text);
							break;
						case "-":
						case "+":
							stackInsertBinary(Level.addition, t.text);
							break;
						case "/":
						case "||":
							stackInsertBinary(Level.multiplication, t.text);
							break;
						default:
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
							stackPopTo(Level.dbt);
							auto n = stack[$ - 1];
							enforce(n.type == "%if" || n.type == "%for",
								"Found " ~ t.kind ~ " but expected end" ~ n.type[1..$]
							);
							n.tokenIndent[tokenIndex] = 0;
							break;
						case "endfor":
						case "endif":
							auto n = stackExit(Level.dbt, "%" ~ t.kind[3 .. $]);
							enforce(n.type.endsWith("%" ~ t.kind[3 .. $]),
								"Found " ~ t.kind ~ " but expected end" ~ n.type[1..$]
							);
							n.tokenIndent[tokenIndex] = 0;
							break;
						case "endmacro":
						case "endfilter":
						case "endset":
							wsPost = WhiteSpace.blankLine;
							goto case "endfor";
						default:
							break;
					}
				},
				(ref const TokenDbtComment t)
				{
					wsPre = wsPost = WhiteSpace.newLine;
				},
			);

			whiteSpace[tokenIndex].maximize(wsPre);
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

	// Comments generally describe the thing below them,
	// so evict them out of blocks if they are on the border.
	{
		void adjust(Node* n)
		{
			alias isComment = n => n.match!(
				(ref const TokenComment t) => true,
				(ref const _) => false
			);
			while (n.start < n.end && isComment(tokens[n.start]))
				n.start++;
			while (n.end > n.start && isComment(tokens[n.end - 1]))
				n.end--;
			foreach (child; n.children)
				adjust(child);
		}
		adjust(&root);
	}

	// AND should always have line breaks when nested directly in a WHERE.
	{
		void adjust(Node* n, Node* parent)
		{
			if (n.level == Level.and && (parent.level == Level.select || parent.level == Level.on))
				foreach (tokenIndex, _; n.tokenIndent)
					whiteSpace[tokenIndex].maximize(WhiteSpace.newLine);
			foreach (child; n.children)
				adjust(child, n);
		}
		adjust(&root, null);
	}

	size_t typicalLength(size_t tokenIndex)
	{
		return tokens[tokenIndex].match!(
			(ref const TokenWhiteSpace t) => 0,
			(ref const TokenComment t) => 60,
			(ref const TokenKeyword t) => t.text.split(" ").length * (5 + 1),
			(ref const TokenIdentifier t)
			{
				import std.ascii : isAlphaNum;

				bool wasLetter;
				size_t length;

				void handle(dchar c)
				{
					bool isLetter = c >= 0x80 || isAlphaNum(cast(char)c);
					if (!isLetter)
						length++;
					else
						if (!wasLetter)
							length += 5;
					wasLetter = isLetter;
				}

				foreach (e; t.text)
					e.match!(
						(dchar c) { handle(c); },
						(ref const DbtExpression e) { foreach (c; e.expr) handle(c); },
					);

				return length;
			},
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
		size_t i = root.start;

		int scan(Node* n)
		in (i == n.start)
		out(; i == n.end)
		{
			int complexity = 0;

			foreach (childIndex; 0 .. n.children.length + 1)
			{
				// Process the gap before this child
				auto gapEnd = childIndex < n.children.length ? n.children[childIndex].start : n.end;
				while (true)
				{
					if (i < gapEnd)
						complexity += typicalLength(i);

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
					complexity += scan(n.children[childIndex]);
			}

			void breakNode(Node* n)
			{
				if (n.breaksApplied)
					return;
				n.breaksApplied = true;

				foreach (i, _; n.softLineBreak)
					whiteSpace[i].maximize(WhiteSpace.newLine);

				foreach (child; n.children)
					if (child.breakWithParent)
						breakNode(child);
			}

			if (complexity >= maxLineComplexity)
			{
				// Do a second pass, converting soft line breaks to hard
				breakNode(n);
			}

			// Propagate breaks to siblings, if requested
			if (n.children.any!(c => c.breaksApplied))
				n.children.filter!(c => c.breakWithSibling).each!breakNode;

			return complexity;
		}
		scan(&root);
	}

	// Decide if we want to apply indentation on a per-node basis.
	{
		size_t i = root.start;

		bool scan(Node* n)
		in (i == n.start)
		out(; i == n.end)
		{
			bool hasLineBreaks;

			foreach (childIndex; 0 .. n.children.length + 1)
			{
				// Process the gap before this child
				auto gapEnd = childIndex < n.children.length ? n.children[childIndex].start : n.end;
				while (i < gapEnd)
				{
					if (i > n.start)
						hasLineBreaks |= whiteSpace[i] >= WhiteSpace.newLine;
					i++;
				}

				// Process the child
				if (childIndex < n.children.length)
					hasLineBreaks |= scan(n.children[childIndex]);
			}

			if (n.conditionalIndent)
				if (!(hasLineBreaks && whiteSpace[n.start] >= WhiteSpace.newLine))
				{
					// We decided to not indent this node, clear its indentation information
					n.indent = 0;
					n.tokenIndent = null;
				}

			return hasLineBreaks;
		}
		scan(&root);
	}

	// Convert nested hierarchy into flattened indentation.
	auto indent = new sizediff_t[tokens.length + 1];
	{
		int currentIndent;
		size_t i = root.start;

		void scan(Node* n)
		in (i == n.start)
		out(; i == n.end)
		{
			foreach (childIndex; 0 .. n.children.length + 1)
			{
				// Process the gap before this child
				// auto gapStart = i;
				auto gapEnd = childIndex < n.children.length ? n.children[childIndex].start : n.end;
				while (i < gapEnd)
					indent[i++] = currentIndent + n.indent;

				// Process the child
				if (childIndex < n.children.length)
				{
					auto child = n.children[childIndex];
					auto childIndent = n.indent;
					if (child.parentIndentOverride != typeof(*child).init.parentIndentOverride)
						childIndent = child.parentIndentOverride;

					currentIndent += childIndent;
					scope(success) currentIndent -= childIndent;

					scan(child);
				}
			}

			// Apply per-token indents at this level
			foreach (tokenIndex, tokenIndent; n.tokenIndent)
				indent[tokenIndex] += tokenIndent - n.indent;
		}
		scan(&root);

		assert(currentIndent == 0);
		assert(i == root.end);
	}

	// Style tweak: remove space on the inside of ( and )
	foreach (i; 0 .. tokens.length)
	{
		if (tokens[i].among(Token(TokenOperator("(")), Token(TokenOperator("["))) && whiteSpace[i + 1] == WhiteSpace.space)
			whiteSpace[i + 1] = WhiteSpace.none;
		if (tokens[i].among(Token(TokenOperator(")")), Token(TokenOperator("]"))) && whiteSpace[i] == WhiteSpace.space)
			whiteSpace[i] = WhiteSpace.none;
	}

	// Make another pass to avoid excessively deep comment indentation
	foreach_reverse (i; 0 .. tokens.length)
		tokens[i].match!(
			(ref const TokenComment t) { indent[i].minimize(indent[i + 1]); },
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
					result ~= Token(TokenWhiteSpace("\n" ~ " ".replicate(indent[i].max(0))));
					break;
			}
		else
			result ~= Token(TokenWhiteSpace(" ".replicate(indent[i].max(0)))); // Pedantic - should always be 0
		result ~= tokens[i];
	}

	if (tokens.length)
		result ~= Token(TokenWhiteSpace("\n"));

	return result;
}
