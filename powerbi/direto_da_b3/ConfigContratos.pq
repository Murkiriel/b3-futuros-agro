// Contratos buscados no boletim da B3. Para incluir outro, acrescente uma linha
// com o tamanho do contrato (unidades por contrato, usado no valor por contrato).
#table(
    type table [Contrato = text, Descrição = text, Unidade = text, Tamanho = number],
    {
        {"BGI", "Boi gordo", "@ (arroba)", 330},
        {"CCM", "Milho", "saca 60 kg", 450},
        {"SJC", "Soja cross (Chicago)", "saca 60 kg", 450}
    }
)
