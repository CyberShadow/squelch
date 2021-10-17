module squelch.common;

import std.sumtype;

// Dbt interpolation:

struct QuotingContext
{
	char quote; // 0 if no quoting
	bool raw;
	bool triple;
}

/// Fragment of DbtString containing a DbtExpression
struct DbtExpression
{
	string expr;
	QuotingContext quoting;
}

alias DbtStringElem = SumType!(
	dchar, // literal character
	DbtExpression, // {{ ... }}
);

alias DbtString = DbtStringElem[];

string tryToString(DbtString s)
{
	string result = "";
	foreach (e; s)
		if (!e.match!(
			(dchar c) { result ~= c; return true; },
			(DbtExpression _) { return false; },
		))
			return null;
	return result;
}

// Tokens:

struct TokenWhiteSpace
{
	string text;
}

struct TokenComment
{
	string text;
}

struct TokenKeyword
{
	string text;
}

struct TokenIdentifier
{
	DbtString text;
}

struct TokenNamedParameter
{
	string text;
}

struct TokenOperator
{
	string text;
}

/// Distinguish < / > from the binary operator.
struct TokenAngleBracket
{
	string text;
}

struct TokenString
{
	DbtString text;
	bool bytes;
}

struct TokenNumber
{
	string text;
}

struct TokenDbtStatement
{
	string text;
	string kind;
}

// struct TokenDbtExpression
// {
// 	string text;
// }

struct TokenDbtComment
{
	string text;
}

alias Token = SumType!(
	TokenWhiteSpace,
	TokenComment,
	TokenKeyword,
	TokenIdentifier,
	TokenNamedParameter,
	TokenOperator,
	TokenAngleBracket,
	TokenString,
	TokenNumber,
	TokenDbtStatement,
	// TokenDbtExpression,
	TokenDbtComment,
);
