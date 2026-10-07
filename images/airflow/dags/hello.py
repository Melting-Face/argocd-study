"""KST 시각을 출력하는 학습용 hello DAG."""

import pendulum
from airflow.sdk import dag, task

# 타임존 정책: 스케줄·표시는 KST. tz-aware 객체만 쓰고 naive datetime은 쓰지 않는다.
KST = pendulum.timezone("Asia/Seoul")


@dag(
    dag_id="hello",
    start_date=pendulum.datetime(2026, 1, 1, tz="Asia/Seoul"),
    schedule=None,  # 수동 트리거 전용
    catchup=False,
    tags=["study"],
)
def hello():
    @task
    def say_hello():
        # 현재 시각을 KST로 출력한다
        print(f"hello from Airflow, now (KST) = {pendulum.now(KST).isoformat()}")

    say_hello()


hello()
