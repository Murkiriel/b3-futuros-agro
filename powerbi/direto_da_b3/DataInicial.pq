// Primeiro pregão a buscar. A cada atualização o Power BI baixa de novo todos os
// dias a partir desta data (60-160 KB por dia).
#date(2026, 10, 1) meta [IsParameterQuery = true, Type = "Date", IsParameterQueryRequired = true]
