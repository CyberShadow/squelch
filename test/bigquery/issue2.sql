WITH
  subquery AS (
    SELECT
      field1,
      field2,
      field3,
      field4 AS {{ name }}
    FROM
      {{ "{{ ref('table_reference') }}" }}
  )
SELECT
  *
FROM
  subquery
