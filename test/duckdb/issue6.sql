PRINTF(
  $$weight: %'d
  wmean: %.2g
  wpred_mean: %.2g
  sum_kpi: %'d
  sum_pred_kpi: %'d$$,
  CAST(total_weight AS INT64),
  SUM(weight * kpi) / total_weight,
  SUM(weight * pred_kpi) / total_weight,
  CAST(SUM(kpi) AS INT64),
  CAST(SUM(pred_kpi) AS INT64)
) AS wbias_tooltip;

PRINTF(
  'weight: %''d
wsmape: %.2g',
  CAST(total_weight AS INT64),
    SUM(weight * ABS(pred_kpi - kpi) * 2 / (pred_kpi + kpi))
  / total_weight
) AS wsmaspe_tooltip;
