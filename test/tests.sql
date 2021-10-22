SELECT
  *
FROM
  data-customers-287.mydatabase.mytable;

SELECT
  'abc',
  "it's",
  'Title: "Boy"',
  'abc',
  'Title:"Boy"',
  'two,\n    lines',
  'why?',
  'abc+',
  r'f\(abc,(.*),def\)',
  b'abc',
  b'abc+',
  '\x01',
  "'",
;

SELECT
  NUMERIC '0';

SELECT
  NUMERIC '123456';

SELECT
  NUMERIC '-3.14';

SELECT
  NUMERIC '-0.54321';

SELECT
  NUMERIC '1.23456e05';

SELECT
  NUMERIC '-9.876e-3';

SELECT
  BIGNUMERIC '0';

SELECT
  BIGNUMERIC '123456';

SELECT
  BIGNUMERIC '-3.14';

SELECT
  BIGNUMERIC '-0.54321';

SELECT
  BIGNUMERIC '1.23456e05';

SELECT
  BIGNUMERIC '-9.876e-3';

SELECT
  123.456e-67,
  .1e4,
  58.,
  4e2,
;

SELECT
  [1, 2, 3],
  ['x', 'y', 'xy'],
  ARRAY[1, 2, 3],
  ARRAY<string>['x', 'y', 'xy'],
  ARRAY<int64>[],
;

SELECT
  (1, 2, 3),
  (1, 'abc'),
  STRUCT(1 AS foo, 'abc' AS bar),
  STRUCT<INT32, INT64>(1, 2),
  STRUCT(1),
  STRUCT<INT64>(1),
;

-- ----------------------------------------------------------------------------------------------------------
SELECT
  1,
;

SELECT
  *
FROM
  tbl;

WITH
  foo AS (
    SELECT
      1
  )
SELECT
  *
FROM
  foo;

SELECT
  *
FROM
  UNNEST(
    ARRAY<int64>[1, 2, 3]
  ) AS number
EXCEPT DISTINCT
SELECT
  1;

WITH
  foo AS (
    SELECT
      *
    FROM
      a
  UNION ALL
    SELECT
      *
    FROM
      b
  )
SELECT
  1;

SELECT
  CASE
    WHEN a THEN 10
    WHEN b THEN 20
    ELSE 30
  END;

SELECT
  CURRENT_DATE();

CREATE OR REPLACE FUNCTION fun() RETURNS ARRAY<STRUCT<a INTEGER, b INTEGER>> AS (
  ARRAY(
    (
      SELECT
        STRUCT(1, 1)
    )
  )
);

WITH
  foo AS (
    SELECT
      1
  ),

  bar AS (
    SELECT
      2
  )
SELECT
  1;

SELECT
  fun(1),
  fun(1, 2),
  fun(1, 2, 3),
  fun(1, 2, 3, 4),
  fun(
    1,
    2,
    3,
    4,
    5
  );

SELECT
  x * (1 - x) * (
    (x * x) / (1 + x) - x - x
  );

{# comment1 #}
{# comment2 #}
SELECT
  1
WINDOW
  a AS (PARTITION BY b ORDER BY c),
  d AS (PARTITION BY e ORDER BY f);

SELECT
  EXTRACT(HOUR FROM foo);

{{ a }}

{{ config() }}

{{ b }} {{ c }}
--
SELECT
  item,
  purchases,
  category,
  LAST_VALUE(item) OVER (item_window) AS most_popular
FROM
  Produce
WINDOW
  item_window AS (
    PARTITION BY
      category
    ORDER BY
      purchases
    ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING
  );

SELECT
  thing
-- filter by size
WHERE
  size > 5
FROM
  things;

SELECT
  * EXCEPT foo
FROM
  bar;

SELECT
  *
FROM
  FOO
JOIN bar
  ON
    baz
    AND quuz
    AND x BETWEEN y AND z
    AND xyzzy;

SELECT
  COUNT(foo) OVER (PARTITION BY bar);

WITH
  a AS (
    SELECT
      b
    WHERE
      c IS NULL
  )
SELECT
  1;

SELECT
  IF(x IS NULL, 0, 1);
