# A board job's cron schedule: field order matters, and a wrong order fails silently

## The pattern

`d2 tira.job.*` schedules run on standard 5-field cron: `minute hour
day-of-month month day-of-week`. Writing "every 30 minutes" as `* */30 * * *`
puts the step in the wrong field - `*/30` in the **hour** field only ever
matches hour `0` (hours run 0-23, and 30 is out of range for every other
hour), while `*` in the **minute** field means every minute. The result is a
job that fires once a minute for one hour a day (midnight to 1am local) and
never at any other time - not "every 30 minutes, always."

The correct form puts the step in the **minute** field: `*/30 * * * *`.

## Why it went unnoticed

Nothing about the malformed schedule looks wrong on a listing - `d2
tira.job.list` shows a schedule string, not what it evaluates to at the
current moment. The defect only became visible as a recurring `job-due`
notification firing roughly once a minute during hour 0, which read as
noise before it was traced back to the schedule field itself (DD-841).

## Checking a job's schedule for this shape

Any 5-field cron string with `*` in the minute position and a `*/N` step
anywhere else is worth a second look - the step almost always belongs in
the minute field for a "every N minutes" job. Compare against the board's
other scheduled jobs: this project's JOB-002 (`0 * * * *`, hourly),
JOB-003/JOB-004 (`0 */2 * * *` / `0 */3 * * *`, every 2/3 hours), JOB-005/
JOB-007 (`*/30 * * * *` / `*/15 * * * *`, every 30/15 minutes) all put the
step where it belongs.
