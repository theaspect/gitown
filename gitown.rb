require 'rugged'

require 'json'
require 'date'

class StatCache
  attr_reader :commits
  attr_reader :blobs
  attr_reader :authors
  attr_reader :replacements

  def initialize(path, output, branch, limit, replacements={})
    @path = path
    @output = output
    @replacements = replacements
    @branch = branch
    @limit = limit

    @repo = Rugged::Repository.new(path)    

    # Cached data
    @authors = Hash.new
    @commits = Hash.new
    @blobs = Hash.new
  end
  
  def walker()
    Rugged::Walker.walk(@repo, 
          show: @repo.branches[@branch].target_id, 
          sort: Rugged::SORT_DATE|Rugged::SORT_TOPO|Rugged::SORT_REVERSE
        ).first(@limit)
  end

  def get_commit(hash)
    if not @commits.key?(hash) then
      begin
        author = @repo.lookup(hash).author[:email]
      rescue => e
        puts hash
        raise e
      end
      @commits[hash] = author
      @authors[get_name(author)] = 0
    #else
      #puts "Skip author"
    end

    @commits[hash]
  end
  
  def annotate_file(commit, root, entry)
    if not @blobs.key?(entry[:oid]) then
      stats = Hash.new(0)
      begin
        command = "git --no-pager -C #{@path} blame -l -r #{commit.oid} -- '#{root}#{entry[:name]}'"
        output = `#{command}`
        output.each_line { |r|
          begin
            # looks like bug in git blame
            # command could return ^24aab5e4254889039a3aa64d810f47d487aefd9 (john 2013-04-17 21:32:40 +0400 1) someline
            author = get_commit(if r[0]!='^' then r[0,39] else r[1,39] end) 
            stats[get_name(author)]+=1
          rescue => e
            puts r
            raise e
          end
        }
      rescue => e
        puts command
        raise e
      end
      @blobs[entry[:oid]] = stats
    #else
      #puts "Skip blob"
    end
    
    @blobs[entry[:oid]]
  end
  
  def get_name(name)
    if @replacements.key? name then
      @replacements[name]
    else
      name
    end
  end
  
  def write_totals()
    puts "Commits #{@commits.count}"
    puts "Blobs #{@blobs.count}"
    puts "Authors #{@authors.keys}"
  end
  
  def write_output(result)
    write_totals
    
    # Sort
    sorted_stats = result.sort_by{|k,v| k}.to_h # {date: stats,...}
    # Populate authors for early commits
    sorted_stats.each{|date,stats| stats.merge!(@authors){|key,v1,v2| if v1 then v1 else v2 end }}

    begin
      File.open(@output,'w') do |f|
        f.write(JSON.pretty_generate(sorted_stats))
      end
    rescue => e
      puts "Cannot write to #{@output}"
      raise e
    end
  end
  
  def gather_stats()
    result = Hash.new

    each_commit() do |c, time|
      # Gather stats once per day
      time = c.time.strftime('%F')
      if result.key? time then
          #puts "Skip #{time}"
          next
      end

      result[time] = inject_blobs(c){|r, e, stats| stats.merge!(annotate_file(c,r,e)) { |key, v1, v2| v1+v2 }}
    end

    result
  end
  
  def each_commit()
    commits_count = walker.count()
    cc = 0
    walker.each_entry { |c|
        # Format time as "2016-12-31"
        time = c.time.strftime('%F')

        cc+=1
        print "#{cc}/#{commits_count} for #{time}\r"

        yield c, time
    }
  end
  
  def inject_blobs(c, stats=Hash.new(0))
    files_count = c.tree.count_recursive()
    #puts "Files #{files_count}"
    i = 0
    c.tree.walk_blobs(:preorder) { |r, e|
        i += 1
        blob = @repo.lookup(e[:oid])
        if not blob.binary? then
          yield r,e, stats # Each blob
        end
        #puts "#{i} out of #{files_count}" if i % 100 == 0
    }
    stats
  end
end

# {
#   "path": "/Users/name/repo", /* Required */
#   "branch": "master",
#   "limit": 1000,
#   "output": "output.json",
#   "replacements": {
#     "john.doe@example.com": "J.Doe"
#   }
# }

# Parse config
config_file = if ARGV[0] then ARGV[0] else 'config.json' end
begin
  config = JSON.parse(File.read(config_file))
  puts config
rescue => e
  puts "Cannot parse #{config_file}"
  puts "Run ruby gitown.rb config.json"
  raise e
end

cache = StatCache.new \
  config.fetch('path'), \
  config.fetch('output', 'output.json'), \
  config.fetch('branch','master'), \
  config.fetch('limit',1000000), \
  config.fetch('replacements',{})

result = cache.gather_stats
cache.write_output result

