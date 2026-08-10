from sqlalchemy import create_engine, text

engine = create_engine("mysql+pymysql://root:investorG1$@192.168.1.153:3306/inventory_procurement")
with engine.connect() as conn:
    print(conn.execute(text("SELECT CURRENT_USER()")).scalar())
