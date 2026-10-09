// Situação de cada dia: OK, Sem pregão (feriado), Ainda não publicado ou Erro.
// Útil para um cartão/tabela no relatório que mostre dias com problema.
let
    Base = Table.AddColumn(
        BaseDias, "Vencimentos", each if [Dados] = null then 0 else Table.RowCount([Dados]), Int64.Type
    ),
    Final = Table.SelectColumns(Base, {"Data", "Status", "Vencimentos", "Detalhe"})
in
    Final
