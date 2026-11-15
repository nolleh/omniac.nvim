"""A compact task summary for a developer's status bar."""


def summarize_tasks(tasks):
    titles = ", ".join(tasks)
    return f"{len(tasks)} tasks: {titles}"


if __name__ == "__main__":
    tasks = ["Write docs", "Fix tests", "Review changes", "Ship release"]
    print(summarize_tasks(tasks))
