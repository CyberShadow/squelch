module squelch.write;

import std.algorithm.iteration;
import std.algorithm.searching;
import std.array;
import std.stdio : File;
import std.string;
import std.sumtype : match;

import ae.utils.array;

import squelch.common;

void save(Token[] tokens, Dialect dialect, File output)
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
				output.write("--", t.text.length ? " " : "", t.text);
			},
			(ref TokenKeyword t)
			{
				output.write(t.text);
			},
			(ref TokenIdentifier t)
			{
				output.write(encode(t.text, true, dialect));
			},
			(ref TokenNamedParameter t)
			{
				output.write(dialect == Dialect.postgresql ? `$` : `@`, t.text);
			},
			(ref TokenOperator t)
			{
				output.write(t.text);
			},
			(ref TokenAngleBracket t)
			{
				output.write(t.text);
			},
			(ref TokenString t)
			{
				if (t.bytes)
					output.write('b');
				output.write(encode(t.text, false, dialect));
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

string encode(ref const scope DbtString str, bool identifier, Dialect dialect)
{
	// Try all encodings, and pick the shortest one.
	final switch (dialect)
	{
		case Dialect.bigquery:
			string bestEnc;
			foreach (quoteChar; identifier ? ['\0', '`'] : ['\'', '"'])
				foreach (raw; quoteChar ? [false, true] : [false])
				  encLoop:
					foreach (triple; quoteChar ? [false, true] : [false])
					{
						import squelch.lex : isIdentifierStart, isIdentifierContinuation, keywords;

						auto delimiter = replicate([DbtStringElem(quoteChar)], quoteChar ? triple ? 3 : 1 : 0);
						auto delimiterStr = delimiter.tryToString();

						if (raw && str.canFind(delimiter))
							continue; // not representable in this encoding

						string enc = "";
						if (raw)
							enc ~= 'r';
						enc ~= delimiterStr;

						auto s = str[];
						while (s.length)
						{
							auto rest = s;
							bool ok = s.shift.match!(
								(dchar c)
								{
									if (!quoteChar)
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
												if ((delimiter.length && rest.startsWith(delimiter)) || c == '\\')
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
									if (e.quoting != QuotingContext(delimiterStr, raw))
										return false;
									enc ~= "{{" ~ e.expr ~ "}}";
									return true;
								}
							);
							if (!ok)
								continue encLoop;
						}
						enc ~= delimiterStr;

						if (!quoteChar)
						{
							if (enc.length == 0 || keywords.canFind!(kwd => kwd.icmp(enc) == 0))
								continue encLoop;
						}

						if (!bestEnc || enc.length < bestEnc.length)
							bestEnc = enc;
					}
			assert(bestEnc, "Failed to encode string: " ~ format("%(%s%)", [str]));
			return bestEnc;

		case Dialect.duckdb:
			string bestEnc;
			foreach (quote; identifier ? [``, `"`] : [`'`, `$$`])
			  duckEncLoop:
				foreach (escaped; quote == `'` ? [false, true] : [false])
					{
						// Repeat the quote character twice to insert it literally once
						auto doubleEscape = quote.length == 1;

						import squelch.lex : isIdentifierStart, isIdentifierContinuation, keywords;

						auto delimiter = quote.map!(c => DbtStringElem(c)).array;

						if (delimiter.length && !doubleEscape && str.canFind(delimiter))
							continue; // not representable in this encoding

						string enc = "";
						if (escaped)
							enc ~= 'e';
						enc ~= quote;

						auto s = str[];
						while (s.length)
						{
							auto rest = s;
							bool ok = s.shift.match!(
								(dchar c)
								{
									if (!quote.length)
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
										if (escaped)
											enc ~= `\n`;
										else
											enc ~= '\n';
										return true;
									}

									if (doubleEscape && c == quote[0])
									{
										enc ~= c;
										enc ~= c;
										return true;
									}

									if (escaped)
									{
										switch (c)
										{
											case '\b': enc ~= `\b`; return true;
											case '\f': enc ~= `\f`; return true;
											case '\n': enc ~= `\n`; return true;
											case '\r': enc ~= `\r`; return true;
											case '\t': enc ~= `\t`; return true;
											default:
										}
									}

									if (c >= 0x20)
									{
										enc ~= c;
										return true;
									}

									return false;
								},
								(DbtExpression e)
								{
									if (e.quoting != QuotingContext(quote, !escaped))
										return false;
									enc ~= "{{" ~ e.expr ~ "}}";
									return true;
								}
							);
							if (!ok)
								continue duckEncLoop;
						}
						enc ~= quote;

						if (!quote.length)
						{
							if (enc.length == 0 || keywords.canFind!(kwd => kwd.icmp(enc) == 0))
								continue duckEncLoop;
						}

						if (!bestEnc || enc.length < bestEnc.length)
							bestEnc = enc;
					}
			assert(bestEnc, "Failed to encode string: " ~ format("%(%s%)", [str]));
			return bestEnc;
			
		case Dialect.postgresql:
			string bestEnc;
		  pgEncLoop:
			foreach (quote; identifier ? [``, `"`] : [`'`])
			{
				// Repeat the quote character twice to insert it literally once
				auto doubleEscape = quote.length == 1;

				import squelch.lex : isIdentifierStart, isIdentifierContinuation, keywords;

				auto delimiter = quote.map!(c => DbtStringElem(c)).array;

				if (delimiter.length && !doubleEscape && str.canFind(delimiter))
					continue; // not representable in this encoding

				string enc = "";
				enc ~= quote;

				auto s = str[];
				while (s.length)
				{
					auto rest = s;
					bool ok = s.shift.match!(
						(dchar c)
						{
							if (!quote.length)
							{
								bool first = rest.length == str.length;
								if (c != cast(char)c)
									return false;
								bool ok = first
									? isIdentifierStart(cast(char)c)
									: isIdentifierContinuation(cast(char)c);
								if (!ok)
									return false;

								switch (c)
								{
									case '0':
										..
									case '9':
									case 'a':
										..
									case 'z':
									case '_':
									case '$':
										break;
									default:
										return false;
								}
							}

							if (doubleEscape && c == quote[0])
							{
								enc ~= c;
								enc ~= c;
								return true;
							}

							enc ~= c;
							return true;
						},
						(DbtExpression /*e*/)
						{
							return false; // Not implemented
						}
					);
					if (!ok)
						continue pgEncLoop;
				}
				enc ~= quote;

				if (!quote.length)
				{
					if (enc.length == 0 || keywords.canFind!(kwd => kwd.icmp(enc) == 0))
						continue pgEncLoop;
				}

				if (!bestEnc || enc.length < bestEnc.length)
					bestEnc = enc;
			}
			assert(bestEnc, "Failed to encode string: " ~ format("%(%s%)", [str]));
			return bestEnc;
	}
}
