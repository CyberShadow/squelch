-- assignment operator := in recursive unnest
SELECT
  UNNEST(kpis, RECURSIVE := TRUE),
  col1
FROM
  table;

-- exponent operator **
SELECT
  1 - wresiduals_sq / (wlabels_sq - wlabels ** 2 / w) AS r2,
FROM
  table
WHERE
  wresiduals_sq IS NOT NULL;
