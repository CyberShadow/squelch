module squelch.write;

import std.algorithm.searching;
import std.array;
import std.stdio : File;
import std.string;
import std.sumtype : match;

import ae.utils.array;

import squelch.common;

void save(Token[] tokens, File output)
{
	foreach (token; tokens)
	{
		token.match!(
			(ref TokenWhiteSpace t)
			{
				output.write(t.text);
			},
			(ref TokenComment t)
			{
				output.write("-- ", t.text);
			},
			(ref TokenKeyword t)
			{
				output.write(t.text);
			},
			(ref TokenIdentifier t)
			{
				output.write(encode(t.text, true));
			},
			(ref TokenNamedParameter t)
			{
				output.write(`@`, t.text);
			},
			(ref TokenOperator t)
			{
				output.write(t.text);
			},
			(ref TokenString t)
			{
				if (t.bytes)
					output.write('b');
				output.write(encode(t.text, false));
			},
			(ref TokenNumber t)
			{
				output.write(t.text);
			},
			(ref TokenDbtStatement t)
			{
				output.write("{%", t.text, "%}");
			},
			(ref TokenDbtComment t)
			{
				output.write("{#", t.text, "#}");
			},
		);
	}
}

string encode(ref const scope DbtString str, bool identifier)
{
	// Try all encodings, and pick the shortest one.
	string bestEnc;
	foreach (quote; identifier ? ['\0', '`'] : ['\'', '"'])
		foreach (raw; quote ? [false, true] : [false])
		  encLoop:
			foreach (triple; quote ? [false, true] : [false])
			{
				import squelch.lex : isIdentifierStart, isIdentifierContinuation, keywords;

				auto delimeter = replicate([DbtStringElem(quote)], quote ? triple ? 3 : 1 : 0);
				auto delimeterStr = delimeter.tryToString();

				if (raw && str.canFind(delimeter))
					continue; // not representable in this encoding

				string enc = "";
				if (raw)
					enc ~= 'r';
				enc ~= delimeterStr;

				auto s = str[];
				while (s.length)
				{
					auto rest = s;
					bool ok = s.shift.match!(
						(dchar c)
						{
							if (!quote)
							{
								bool first = rest.length == str.length;
								if (c != cast(char)c)
									return false;
								bool ok = first
									? isIdentifierStart(cast(char)c)
									: isIdentifierContinuation(cast(char)c);
								if (!ok)
									return false;
							}

							if (c == '\n')
							{
								if (triple)
								{
									enc ~= '\n';
									return true;
								}
								if (!raw)
								{
									enc ~= `\n`;
									return true;
								}
							}

							if (raw && c < 0x20)
								return false;

							if (!raw)
							{
								switch (c)
								{
									case '\a': enc ~= `\a`; return true;
									case '\b': enc ~= `\b`; return true;
									case '\f': enc ~= `\f`; return true;
									case '\n': enc ~= `\n`; return true;
									case '\r': enc ~= `\r`; return true;
									case '\t': enc ~= `\t`; return true;
									case '\v': enc ~= `\v`; return true;
									default:
										if (c < 0x20)
										{
											enc ~= format(`\x%02x`, uint(c));
											return true;
										}
										if ((delimeter.length && rest.startsWith(delimeter)) || c == '\\')
										{
											enc ~= '\\';
											enc ~= c;
											return true;
										}
								}
							}

							enc ~= c;
							return true;
						},
						(DbtExpression e)
						{
							if (e.quoting != QuotingContext(quote, raw, triple))
								return false;
							enc ~= "{{" ~ e.expr ~ "}}";
							return true;
						}
					);
					if (!ok)
						continue encLoop;
				}
				enc ~= delimeterStr;

				if (!quote)
				{
					if (enc.length == 0 || keywords.canFind!(kwd => kwd.icmp(enc) == 0))
						continue encLoop;
				}

				if (!bestEnc || enc.length < bestEnc.length)
					bestEnc = enc;
			}
	assert(bestEnc, "Failed to encode string: " ~ format("%(%s%)", [str]));
	return bestEnc;
}
