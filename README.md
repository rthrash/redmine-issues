# Redmine to Github Issues migration script

Forked from [Diaspora](https://joindiaspora.com/) / @diaspora

## Features

- Original details are recorded in body
 - Author
 - Creation datetime
 - Priority
 - Status
 - Description
- Status of open/closed is carried over.
- Additional statuses are recorded as labels.
- Comments are carried over.
- `commit:` and `#` references should function.
- Optional padding for non-sequential issue IDs.

## Warnings

- It has only been tested against fresh repositories.
- Tested against Redmine 1.3, but >= 1.1 should work.
- News feed and notifications will go batshit crazy.
- ID padding will leave a lot of dummy closed tickets.

## Usage

1. Configure `github.yml` with your details.
1. Run `redmine_to_github_migration.rb`

## Mappings

| Redmine | Github |
| ------- | ------ |
| Project | Project |
| Tracker | Label |
| Subject | Title |
| Description | Body |
| Status | open/close no suitable equivalent |
| Priority | Label |
| Assignee | too hard to accomplish |
| Target Version | Milestone | 
| Resolution | Label |