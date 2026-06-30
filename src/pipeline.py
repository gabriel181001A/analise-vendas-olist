"""
Pipeline de tratamento dos dados da Olist.

Lê os CSVs brutos do Kaggle (data/raw/), aplica as regras de negócio e
exporta uma tabela analítica "flat" (uma linha por pedido) em
data/processed/olist_analitico.csv — a base que alimenta o dashboard no Power BI.

Uso:
    python src/pipeline.py

Pré-requisito: baixar os CSVs do Kaggle e colocar em data/raw/
(https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce)
"""
from pathlib import Path

import pandas as pd

RAW = Path(__file__).resolve().parents[1] / "data" / "raw"
PROCESSED = Path(__file__).resolve().parents[1] / "data" / "processed"

# De-para de categorias (inglês -> português)
TRADUCAO_CATEGORIAS = {
    "toys": "Brinquedos", "sports_leisure": "Esporte e Lazer", "telephony": "Telefonia",
    "furniture_decor": "Móveis e Decoração", "housewares": "Utilidades Domésticas",
    "bed_bath_table": "Cama, Mesa e Banho", "health_beauty": "Beleza e Saúde",
    "computers_accessories": "Informática e Acessórios", "watches_gifts": "Relógios e Presentes",
    "auto": "Automotivo", "perfumery": "Perfumaria", "baby": "Bebês", "stationery": "Papelaria",
    "garden_tools": "Ferramentas de Jardim", "fashion_bags_accessories": "Bolsas e Acessórios",
    "cool_stuff": "Diversos", "pet_shop": "Pet Shop", "office_furniture": "Móveis de Escritório",
    "consoles_games": "Games e Consoles", "audio": "Áudio", "electronics": "Eletrônicos",
    "food_drink": "Alimentos e Bebidas", "small_appliances": "Eletroportáteis",
    "fashion_shoes": "Calçados", "luggage_accessories": "Malas e Acessórios",
    "home_appliances": "Eletrodomésticos", "home_construction": "Construção",
    "construction_tools_construction": "Ferramentas de Construção", "books_general_interest": "Livros",
    "air_conditioning": "Ar-Condicionado", "musical_instruments": "Instrumentos Musicais",
    "fashion_male_clothing": "Moda Masculina", "kitchen_dining_laundry_garden_furniture": "Móveis de Cozinha",
}


def traduzir_categoria(c):
    """Traduz a categoria para PT-BR; se não estiver no de-para, deixa legível."""
    if pd.isna(c):
        return c
    return TRADUCAO_CATEGORIAS.get(c, c.replace("_", " ").title())


def carregar_dados():
    """Lê os CSVs brutos necessários para a base analítica."""
    return {
        "orders": pd.read_csv(RAW / "olist_orders_dataset.csv"),
        "items": pd.read_csv(RAW / "olist_order_items_dataset.csv"),
        "payments": pd.read_csv(RAW / "olist_order_payments_dataset.csv"),
        "reviews": pd.read_csv(RAW / "olist_order_reviews_dataset.csv"),
        "customers": pd.read_csv(RAW / "olist_customers_dataset.csv"),
        "products": pd.read_csv(RAW / "olist_products_dataset.csv"),
        "cat_trans": pd.read_csv(RAW / "product_category_name_translation.csv"),
    }


def preparar_pedidos(orders):
    """Converte datas, filtra pedidos entregues e calcula prazo/atraso (em dias)."""
    date_cols = [
        "order_purchase_timestamp", "order_approved_at",
        "order_delivered_carrier_date", "order_delivered_customer_date",
        "order_estimated_delivery_date",
    ]
    for c in date_cols:
        orders[c] = pd.to_datetime(orders[c], errors="coerce")

    delivered = orders[orders["order_status"] == "delivered"].copy()
    delivered["tempo_entrega_dias"] = (
        delivered["order_delivered_customer_date"] - delivered["order_purchase_timestamp"]
    ).dt.days
    delivered["atraso_dias"] = (
        delivered["order_delivered_customer_date"] - delivered["order_estimated_delivery_date"]
    ).dt.days
    return delivered


def categoria_principal_por_pedido(items, products, cat_trans):
    """Define a categoria de cada pedido como a mais frequente entre seus itens (traduzida)."""
    prod_cat = products.merge(cat_trans, on="product_category_name", how="left")
    itens = items.merge(
        prod_cat[["product_id", "product_category_name_english"]], on="product_id", how="left"
    )
    itens["categoria"] = itens["product_category_name_english"].apply(traduzir_categoria)
    return (
        itens.groupby("order_id")["categoria"]
        .agg(lambda s: s.mode().iat[0] if not s.mode().empty else None)
        .reset_index()
    )


def montar_base_analitica(dados):
    """Junta tudo numa tabela flat (uma linha por pedido) pronta para o Power BI."""
    delivered = preparar_pedidos(dados["orders"])
    pay_agg = dados["payments"].groupby("order_id")["payment_value"].sum().reset_index()
    rev_agg = dados["reviews"].groupby("order_id")["review_score"].mean().reset_index()
    cat_agg = categoria_principal_por_pedido(dados["items"], dados["products"], dados["cat_trans"])

    flat = (
        delivered
        .merge(
            dados["customers"][["customer_id", "customer_unique_id", "customer_state", "customer_city"]],
            on="customer_id", how="left",
        )
        .merge(pay_agg, on="order_id", how="left")
        .merge(rev_agg, on="order_id", how="left")
        .merge(cat_agg, on="order_id", how="left")
    )
    # Coluna "Ano-Mês" (ex: 2017-10) para a linha do tempo contínua no dashboard
    flat["ano_mes"] = flat["order_purchase_timestamp"].dt.to_period("M").astype(str)

    cols = [
        "order_id", "customer_unique_id", "customer_state", "customer_city",
        "order_purchase_timestamp", "ano_mes", "categoria", "tempo_entrega_dias",
        "atraso_dias", "payment_value", "review_score",
    ]
    return flat[cols]


def main():
    PROCESSED.mkdir(parents=True, exist_ok=True)
    dados = carregar_dados()
    base = montar_base_analitica(dados)
    saida = PROCESSED / "olist_analitico.csv"
    base.to_csv(saida, index=False)
    print(f"Base analitica exportada: {saida} ({len(base):,} linhas)")


if __name__ == "__main__":
    main()
