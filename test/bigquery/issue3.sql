SELECT
  PARSE_JSON('{"id":922337203685477580701}') AS json_data;

-- fails
SELECT
  PARSE_JSON('{"id":922337203685477580701}', wide_number_mode => 'exact') AS json_data;

-- fails
SELECT
  PARSE_JSON('{"id":922337203685477580701}', wide_number_mode => 'round') AS json_data;

SELECT
  TO_JSON(9007199254740993, stringify_wide_numbers => TRUE) AS stringify_on;

WITH
  T1 AS (
    (
      SELECT
        9007199254740993 AS id
    )
  UNION ALL
    (
      SELECT
        2 AS id
    )
  )
SELECT
  TO_JSON(t, stringify_wide_numbers => TRUE) AS json_objects
FROM
  T1 AS t;
