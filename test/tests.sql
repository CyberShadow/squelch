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
  UNNEST(ARRAY<int64>[1, 2, 3]) AS number
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
    WHEN a
      THEN 10
    WHEN b
      THEN 20
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
  fun(a),
  fun(a_b),
  fun(a_b_c),
  fun(a_b_c_d),
  fun(a_b_c_d_e),
  fun(a_b_c_d_e_f),
  fun(a_b_c_d_e_f_g),
  fun(a_b_c_d_e_f_g_h),
  fun(a_b_c_d_e_f_g_h_i),
  fun(a_b_c_d_e_f_g_h_i_j),
  fun(
    a_b_c_d_e_f_g_h_i_j_k
  ),
  fun(
    a_b_c_d_e_f_g_h_i_j_k_l
  ),
  fun(
    a_b_c_d_e_f_g_h_i_j_k_l_m
  ),
  fun(
    a_b_c_d_e_f_g_h_i_j_k_l_m_n
  ),
  fun(
    a_b_c_d_e_f_g_h_i_j_k_l_m_n_o
  ),
  fun(
    a_b_c_d_e_f_g_h_i_j_k_l_m_n_o_p
  );

SELECT
  fun(a_a_a),
  fun(a_a_a, b_b_b),
  fun(a_a_a, b_b_b, c_c_c),
  fun(
    a_a_a,
    b_b_b,
    c_c_c,
    d_d_d
  ),
  fun(
    a_a_a,
    b_b_b,
    c_c_c,
    d_d_d,
    e_e_e
  ),
  fun(
    a_a_a,
    b_b_b,
    c_c_c,
    d_d_d,
    e_e_e,
    f_f_f
  ),
  fun(
    a_a_a,
    b_b_b,
    c_c_c,
    d_d_d,
    e_e_e,
    f_f_f,
    g_g_g
  );

SELECT
    x
  * (1 - x)
  * ((x * x) / (1 + x) - x - x);

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
      AND xyzzy
WHERE
  1 = 1;

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

SELECT
  [1, 2, 3],
  [1, 2, 3],
;

SELECT
  1
WHERE
      x.x = x.x
  AND FUN(x.x) BETWEEN x.x AND x.x;

SELECT
  1
  INNER JOIN (
    SELECT
      a
    FROM
      b
  ) USING (c, d)
WINDOW
  a;

SELECT
  1
WINDOW
  x AS (PARTITION BY b ORDER BY c DESC),
  y AS (PARTITION BY b ORDER BY c DESC);

SELECT
     x / AVG(x) OVER (PARTITION BY x, y)
  AS z
FROM
  foo;

SELECT
       XXXXX_YYYYY_XXXXX((xxxxx_yyyyy_xxxxx / xxxxx_yyyyy_xxxxx - 123) * 123, 123)
     / 123
     * 123
  AS xxxxx_yyyyy_xxxxx;

SELECT
  IFNULL(
    MIN(IF(f = 0, i, NULL)),
    ARRAY_LENGTH(f_f)
  )
FROM
  UNNEST(f_f) AS flag WITH OFFSET AS i;

SELECT
  {% for x in y %}
    {{ x.f }},
  {% else %}
    *
  {% endfor %}
;

WITH
  a_a AS (
    SELECT DISTINCT
      b_b,
      MAX(c_c_c) AS c_c_c,
    FROM
      {{ ref('d_d_d_d') }}
    WHERE
      a_a = b_b_b
    GROUP BY
      c_c
  )
SELECT
  1;

SELECT
  x OVER (PARTITION BY a, b, c),
  y OVER (
    PARTITION BY
      a,
      b,
      c,
      d,
      e,
      f,
      g,
      h
  ),
  z OVER (
    PARTITION BY
      a,
      b,
      c,
      d,
      e,
      f,
      g,
      h,
      i,
      j
  );

SELECT
  *,
  1
FROM
  x;

SELECT DISTINCT AS STRUCT
  x,
  y
FROM
  t;

SELECT
  COUNT(x),
  CASE
    WHEN x = 1
      THEN 1
    WHEN x = 2
      THEN 2
    ELSE 0
  END;

SELECT
  *
FROM
  x
  LEFT JOIN x USING (market, channel, date)
  LEFT JOIN x
    ON
      st.market = tr.market;

SELECT
  1
WINDOW
  x_x AS (
    PARTITION BY
      x,
      x,
      x_x_x
    ORDER BY
      x_x ASC
    ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING
  );

SELECT
     CASE
       WHEN x_x_x IN (
         '1',
         '2',
         '3',
         '4',
         '5',
         '6'
       )
         THEN y
       ELSE y
     END
  AS x_x_x_x;

SELECT
     CASE
       -- x
       WHEN x_x AND x_x_x > x_x
         THEN STRUCT(
           x_x AS x,
           x_x_x - x_x AS x
         )
       WHEN x_x AND x_x_x <= x_x
         THEN STRUCT(0.0 AS x, x_x_x AS x)
       -- x
       WHEN x_x > '' AND x_x_x_x_x > 0
         THEN STRUCT(x_x_x AS x, 0.0 AS x)
       -- x
       ELSE STRUCT(0.0 AS x, 0.0 AS x)
     END
  AS x_x_x;

SELECT
  x
  {% if x %}
    AND x
  {% endif %}
  AND 1;

{% macro x() -%}
  {%- if x -%}
    x
  {%- else -%}
    x
  {%- endif -%}
{%- endmacro %}

SELECT
  1
  {% if x %}
    WHERE
      NOT ({{ x }})
  {%- else %}
    WHERE
      NOT ({{ x }})
  {%- endif %}
;

SELECT
  COUNT(x_x) OVER (PARTITION BY a_a_a_a_a_a_a)
FROM
  x;

   CASE
     WHEN
       MIN(x_x_x_x_x) OVER (PARTITION BY x_x_x)
     = x_x_x_x_x
       THEN 1
     ELSE 0
   END
AS x_x_x_x_x;

SELECT
  *
FROM
  x
WHERE
  x AND x OR x AND x;

SELECT
  *
FROM
  x
WHERE
         x_x_x_x_x_x_x_x_x_x
     AND x_x_x_x_x_x_x_x_x_x
  OR
         x_x_x_x_x_x_x_x_x_x
     AND x_x_x_x_x_x_x_x_x_x;

SELECT
      (1 + 1)
  AND x_x_x_x_x = 1;

SELECT
  *,

     x_x_x_x_x * x_x_x_x_x
  AS a,

  2 AS b;
