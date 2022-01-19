squelch - SQL formatter for BigQuery + Dbt
==========================================

Squelch is an SQL formatter.

Currently, it supports only BigQuery Standard SQL + Dbt/Jinja2 macros.

Try it online: https://squelch-sql-formatter.herokuapp.com/


Usage
-----

Format a file:

    $ squelch file.sql

Format from standard input:

    $ squelch -- - < input.sql > output.sql

`squelch-run` is a script which will build Squelch automatically;
just replace `squelch` with `squelch-run` in the above invocations to use it.



Configuration
-------------

There is no configuration.


License
-------

[Boost Software License, version 1.0](https://www.boost.org/LICENSE_1_0.txt).
