#TODO: Must figure out how to get more than what appears to be a limit of 100 issues … not sure though
#TODO: *** Have it create a comment linking to the new repo on Github? ***
#TODO: Finally, which custom fields we want to limit it to… Environment and affects versions make sense
#TODO: Can we create a list of source/target repos to migrate and have it walk through them, too?

require 'rubygems'
require 'yaml'
require 'rest-client'
require 'json'
require 'octokit'
require 'ruby-debug'

include Octokit
@config_file = "github.yml"

config = YAML.load_file(@config_file)
ghclient = Octokit::Client.new :access_token => config["github"]["token"]
abort "Unable to authenticate to GitHub with supplied credentials." unless ghclient.user.login
puts "Github credentials passed!"


  class IssueMigrator
    attr_accessor :redmine_issues
    attr_accessor :issue_pairs

    def initialize(config)
        @redmine_url = config["redmine"]["url"]
        @redmine_proj = config["redmine"]["project"]
        @github_user = config["github"]["user"]
        @github_repo = config["github"]["repo"]
        @pad_ids = config["github"]["pad_ids"] || false
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
      @repo ||= Octokit::Repository.new(:repo => config["github"]["repo"], :owner => ghclient.user.login)
    end

    def migrate_issues
      self.issue_pairs = []
      redmine_issues.each do |issue|
        migrate_issue issue
      end
    end

    def migrate_issue issue
      print "Migrating issues to github... "
      pad_issues(issue) if @pad_ids
      github_issue = create_issue(issue)
      add_labels(github_issue, issue)
      migrate_comments(github_issue, issue)
      github_issue.close! if ["Closed", "Fixed", "Resolved", "Rejected", "Won't Fix", "Duplicate", "Obsolete", "Implemented"].include? issue["status"]["name"]
      print "."
      self.issue_pairs << [github_issue, issue]
      puts "success!"
      github_issue
    end

    def pad_issues redmine_issue
      last_issue = self.issue_pairs.empty? ? 0 : self.issue_pairs[-1][0].number
      while (last_issue + 1) < redmine_issue["id"].to_i
        last_issue = pad_issue
      end
   end

    def pad_issue
      first_try = true
      params = { :title => "dummy issue", :body => "Dummy issue to pad out numeric IDs. Please disregard." }
      begin
        github_issue = Issue.open(:repo => self.repo, :params => params)
        add_label_to_issue(github_issue, "dummy")
        github_issue.close!
        print "'"
      rescue Exception => e
        if first_try
          first_try = false
          retry
        end
        puts "Dummy issue open failed"
      end
      github_issue.number
    end

    def create_issue redmine_issue
      title = redmine_issue["subject"]
      body = <<BODY
Issue ID <a href="{@redmine_url}/issues/{redmine_issue["id"]}">{redmine_issue["id"]}</a> from #{@redmine_url}/projects/#{@redmine_proj}
Created by: **#{redmine_issue["author"]["name"]}**
On #{DateTime.parse(redmine_issue["created_on"]).asctime}

*Priority: #{redmine_issue["priority"]["name"]}*
*Status: #{redmine_issue["status"]["name"]}*
#{
  custom_fields = ''
  redmine_issue["custom_fields"].each do |field|
    custom_fields << "*#{field["name"]}: #{field["value"]}*\n" unless field["value"].nil? || field["value"] == ''
  end if redmine_issue["custom_fields"]
  custom_fields
}

#{redmine_issue["description"]}
BODY
      begin
        result_issue = Octokit.create_issue(self.repo, title, body)
        result_issue.attrs
      rescue Exception => e
        redmine_issue["retrying?"] = true
        retry unless redmine_issue["retrying?"]
        puts "Issue open failed for Redmine Issue #{redmine_issue["id"]}"
      end
    end
    
    def migrate_labels 
      puts "Migrating labels to github"
      labels = []
      labelhash = {}

      # Collect all possible labels from our issues into a hash,
      #  where the key is the label and the value is 1 to denote truth
      self.redmine_issues.each do |issue|
        ["priority", "tracker", "status"].each do |l|
          labelhash[issue[l]["name"]] = 1 unless labelhash[issue[l]["name"]]
        end
        issue["custom_fields"].each do |l|
          next unless l["name"] = "Resolution"
          labelhash[l["value"]] = 1 unless labelhash[l["value"]]
      end
      
      # Strip out blank labels, convert to lowercase, and strip out spaces
      labelhash.reject!{|key, val| key == ""}
      labels = labelhash.keys.map! {|l| l.downcase.delete(' ')}

      # Check and see what labels are already in the github repo so we cut down on requests
      # If it's already in the repo, don't recreate it
      curlabels = Octokit.labels(self.repo)
      curlabels.each {|c| labels.delete(c[:name])}
      
      # Add each possible label to the repo
      print "Adding #{labels.length} labels to the repo ... "
      labels.each do |label|
        Octokit.add_label(self.repo, label)
      end

      puts "success!"
    end
    
    def migrate_milestones
      puts "Migrating milestones to github"
      milestones = []
      milestoneshash = {}
      
      # Collect all possible milestones from our issues into a hash,
      #  where the key is the hash and the value is 1 to denote truth
      self.redmine_issues.each do |issue|
        if issue["fixed_version"]
          milestoneshash[issue["fixed_version"]["name"]] = 1 unless milestoneshash[issue["fixed_version"]["name"]]
        end
      end
      
      # Strip out blank milestones
      milestoneshash.reject!{|key, val| key == ""}
      milestones = milestoneshash.keys
      
      # Check and see what milestones are already in the github repo so we cut down on requests
      # If it's already in the repo, don't create it
      curmilestones = Octokit.milestones(self.repo)
      curmilestones.each {|c| milestones.delete(c.attrs[:title]) }
      
      # Add each possible milestone to the repo
      print "Adding #{milestones.length} milestones to the repo ... "
      milestones.each do |ms|
        Octokit.create_milestone(self.repo, ms)
      end
      
      puts "success!"
    end

    def add_labels github_issue, redmine_issue
      labels = []
      if priority = redmine_issue["priority"]
        if priority  == "Low"
          add_label_to_issue(github_issue, "Low Priority")
        elsif ["High", "Urgent", "Immediate"].include?(priority)
          add_label_to_issue(github_issue, "High Priority")
        end
      end
      ["tracker", "status", "category"].each do |thing|
        next unless redmine_issue[thing]
        value = redmine_issue[thing]["name"]
        first_try = true
        add_label_to_issue(github_issue, value) unless ["New", "Fixed"].include?(value)
      end
    end

    def add_label_to_issue github_issue, label
      label = "Will Not Fix" if label == "Won't Fix"
      first_try = true
      begin
        github_issue.add_label URI.escape(label)
        print ','
      rescue Exception => e
        puts
        pp e
        puts
        puts label
        puts URI.escape(label)
        if first_try
          first_try = false
          retry
        end
      end
    end

    def migrate_comments github_issue, redmine_issue
      redmine_issue["journals"].each do |j|
        next if j["notes"].nil? || j["notes"] == ''
        github_issue.comment <<COMMENT
Comment by: **#{j["user"]["name"]}**
On #{DateTime.parse(j["created_on"]).asctime}

#{j["notes"]}
COMMENT
      end
    end

    def get_comments redmine_issue
      print "."
      issue_json = JSON.parse(RestClient.get("#{@redmine_url}/issues/#{redmine_issue["id"]}", :params => {:format => :json, :include => :journals}))
      issue_json["issue"]
    end

    def clear_issues
      puts "Clearing issues!"
      issues.each do |i|
        i.close!
        print '.'
      end
    end

    def save_issues_to_file filename
      File.open(filename, 'w') do |f|
        f.write(self.redmine_issues.to_json)
      end
    end
  
    def get_issues_from_file filename
      self.redmine_issues = JSON.parse(File.read(filename))
    end
  end

  
  Octokit.configure do |c|
    c.access_token = config["github"]["token"]
  end
  m = IssueMigrator.new(config)
  
  # Use this to grab issues from redmine and save it out
  # Or comment these two and use the third item to read in from file 
  m.get_issues
  m.save_issues_to_file "migration.json"
  #m.get_issues_from_file "migration.json"

  # Skip these if you've already migrated the labels and milestones for your repo
  m.migrate_labels
  m.migrate_milestones
  
  m.migrate_issues
  puts "Done migrating!"
end
