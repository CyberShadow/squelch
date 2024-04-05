module squelch.main;

import std.exception;
import std.file : readText, rename;
import std.stdio;

import ae.sys.file;
import ae.utils.funopt;
import ae.utils.main;
import ae.utils.text;

import squelch.common : Dialect;
import squelch.lex;
import squelch.format;
import squelch.write;

void program(
	string[] files,
	Dialect dialect = Dialect.bigquery,
)
{
	foreach (fileName; files)
	{
		stderr.writeln("Processing ", fileName);
		auto src = fileName == "-"
			? readFile(stdin).assumeUnique.asText()
			: readText(fileName);
		auto tokens = lex(src, dialect);
		tokens = format(tokens);
		auto o = fileName == "-"
			? stdout
			: File(fileName ~ ".squelch-tmp", "wb");
		save(tokens, dialect, o);
		o.close();
		if (fileName != "-")
			rename(fileName ~ ".squelch-tmp", fileName);
	}
}

mixin main!(funopt!program);
