require 'rubygems'
require 'yaml'
require 'rest-client'
require 'json'
require 'octopi'
require 'ruby-debug'

include Octopi
@config_file = "github.yml"

authenticated :config => @config_file do
  puts "Authenticated!"

  class IssueMigrator
    attr_accessor :redmine_issues
    attr_accessor :issue_pairs

    def initialize(config)
        @redmine_url = config["redmine"]["url"]
        @redmine_proj = config["redmine"]["project"]
        @github_user = config["github"]["user"]
        @github_repo = config["github"]["repo"]
        @pad_ids = config["github"]["pad_ids"] || false

        @closed_statuses = %w{Closed Fixed Rejected Won't Fix Duplicate Obsolete Implemented}
    end

    def get_issues
      offset = 0
      issues = []
      puts "Getting redmine issues!"
      begin
        json = RestClient.get("#{@redmine_url}/projects/#{@redmine_proj}/issues", {:params => {:format => :json, :status_id => '*', :limit => 100, :offset => offset}})
        result = JSON.parse(json)
        issues << [*result["issues"]]
        offset = offset + result['limit']
        print '.'
      end while offset < result['total_count']
      puts

      puts "Retreived redmine issue index."
      issues.flatten!

      puts "Getting comments"
      issues.map! do |issue|
        get_comments(issue)
      end
      puts "Retreived comments."

      self.redmine_issues = issues.reverse!
    end

    def issues
      repo.issues
    end

    def repo
      @repo ||= Repository.find(:name => @github_repo, :user => @github_user)
    end

    def migrate_issues
      self.issue_pairs = []
      redmine_issues.each do |issue|
        migrate_issue issue
      end
    end

    def migrate_issue issue
      save_issue(issue)
      save_comments(issue)
      print "."
    end

    def save_issue redmine_issue
        hash = {
          "url" => "https://api.github.com/repos/#{@github_user}/#{@github_repo}/issues/#{redmine_issue['id']}",
          "html_url" => "https://github.com/#{@github_user}/#{@github_repo}/issues/#{redmine_issue['id']}",
          "number" => redmine_issue["id"],
          "state" => @closed_statuses.include?(redmine_issue["status"]["name"]) ? "closed" : "open",
          "title" => redmine_issue["subject"],
          "body" => redmine_issue['description'],
          "user" => {
            "login" => @github_user,
          },
          "labels" => [
            collect_labels(redmine_issue).each do |label|
              { "name" => label, }
            end
          ],
          "assignee" => {
            "login" => @github_user,
          },
          "milestone" => { },
          "comments" => 0,
          "pull_request" => {
            "html_url" => "https://github.com/#{@github_user}/#{@github_repo}/issues/#{redmine_issue['id']}",
            "diff_url" => "https://github.com/#{@github_user}/#{@github_repo}/issues/#{redmine_issue['id']}.diff",
            "patch_url" => "https://github.com/#{@github_user}/#{@github_repo}/issues/#{redmine_issue['id']}.patch"
          },
          "closed_at" => @closed_statuses.include?(redmine_issue["status"]["name"]) ? Time.parse(redmine_issue["updated_on"]).utc.iso8601 : nil,
          "created_at" => Time.parse(redmine_issue["created_on"]).utc.iso8601,
          "updated_at" => Time.parse(redmine_issue["updated_on"]).utc.iso8601,
        }

        File.open("issues/#{'%03d' % redmine_issue['id']}.json", 'w') do |f|
          #f.write(hash.to_json)
          f.write(JSON.pretty_generate(hash))
        end
      end

    def collect_labels redmine_issue
      labels = []
      if priority = redmine_issue["priority"]
        if priority  == "Low"
          labels << "Low Priority"
        elsif ["High", "Urgent", "Immediate"].include?(priority)
          labels << "High Priority"
        end
      end
      ["tracker", "status", "category"].each do |thing|
        next unless redmine_issue[thing]
        value = redmine_issue[thing]["name"]
        first_try = true
        labels << value unless ["New", "Fixed"].include?(value)
      end
      labels
    end

    def save_comments redmine_issue
      hash = []
      redmine_issue["journals"].each do |j|
        next if j["notes"].nil? || j["notes"] == ''
        hash << {
          "url" => "https://api.github.com/repos/#{@github_user}/#{@github_repo}/issues/comments/#{redmine_issue['id']}",
          "body" => j["notes"],
          "user" => {
            "login" => @github_user,
          },
          "created_at" => Time.parse(j["created_on"]).utc.iso8601,
          "updated_at" => Time.parse(j["created_on"]).utc.iso8601,
        }
      end
      File.open("issues/#{'%03d' % redmine_issue['id']}.comments.json", 'w') do |f|
        #f.write(hash.to_json)
        f.write(JSON.pretty_generate(hash))
      end unless hash.empty?
    end

    def get_comments redmine_issue
      print "."
      issue_json = JSON.parse(RestClient.get("#{@redmine_url}/issues/#{redmine_issue["id"]}", :params => {:format => :json, :include => :journals}))
      issue_json["issue"]
    end

    def save_issues filename
      full_saveable = []
      self.issue_pairs.each do |pair|
        full_saveable << {
          :redmine => pair[1].merge(:url => "#{@redmine_url}/issues/#{pair[1]["id"]}"),
          :github => {
            :url => "#{pair[0].repository.url}/issues/#{pair[0].number}",
            :number => pair[0].number,
            :repo_url => pair[0].repository.url
          }
        }
      end
      File.open(filename, 'w') do |f|
        #f.write(hash.to_json)
        f.write(JSON.pretty_generate(hash))
      end
    end
  end

  config = YAML.load_file(@config_file)
  m = IssueMigrator.new(config)
  m.get_issues

  puts "Migrating issues to github..."
  m.migrate_issues
  puts "Done migrating!"
end
