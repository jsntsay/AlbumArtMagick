# encoding: UTF-8

require 'digest/SHA1'
require 'find'
require 'sqlite3'
require 'quick_magick'

time = Time.now
count = 0

localDir = Array.new
destDir= Array.new
musicTypes = Array.new
imageTypes =  Array.new
originalName= nil
coverWidth = nil
coverHeight = nil
coverType = nil
coverName = nil

#convinence methods

#takes varValue, puts into var (assumes new array), may be multiple values delimited by delim
def setValue(var, varValue, delim)
  #single value (delimited by | )
   if varValue.index(delim) == nil
     var[0] = varValue;
   #multiple values
   else
     s = varValue.split(delim)
     #go through and trim values
     for i in (0..s.size()-1) do
       var[i] = s[i].strip()
     end
   end
end

#finds SHA1 hash of 2nd file in line and appends file size to end
#used for music files
def findLargeHash(f)
  incr_digest = Digest::SHA1.new()
  file = File.open(f, "rb")
  count = 0
  file.each_line do |line|
    if count == 1
      incr_digest << line
    end
    count = count + 1
    if count >= 2
      break
    end
  end
  return incr_digest.hexdigest + File.size(f).to_s(16)
end

#finds SHA1 hash of smaller files (not music)
def findSmallHash(f)
  return Digest::SHA1.file(f).hexdigest()
end

#main script

#read config.ini and get variables
IO.foreach("config.ini") { |line|
  varName = line[0,line.index('=')].strip()
  varValue = line[line.index('=')+1..-1].strip()
  if varName.index('localDir') != nil 
    setValue(localDir,varValue,'|')
  elsif varName.index('destDir') != nil
    setValue(destDir,varValue,'|')
  elsif varName.index('musicTypes') != nil
    setValue(musicTypes,varValue,',')
  elsif varName.index('imageTypes') != nil
    setValue(imageTypes,varValue,',')
  elsif varName.index('originalName') != nil
    originalName = varValue.strip()
  elsif varName.index('coverWidth') != nil
    coverWidth = varValue.strip().to_i
  elsif varName.index('coverHeight') != nil
    coverHeight = varValue.strip().to_i
  elsif varName.index('coverType') != nil
    coverType = varValue.strip()
  elsif varName.index('coverName') != nil
      coverName = varValue.strip()
  end
}

#TODO: error checking for null variables

#check db, if doesn't exist, create
#doesn't exist, create and initalize table
if File.exist?("filesDB.db") == false
  f = File.new("filesDB.db", "w")
  f.close()
  db = SQLite3::Database.new( "filesDB.db" )
  db.execute_batch(
      "create table AlbumFiles ( 
        path varchar2(100) unique,
        originalHash varchar2(50),
        coverHash varchar2(50)
      )")
else
  db = SQLite3::Database.new( "filesDB.db" )
end

#TODO: check for correct tables?

localMusic = Hash.new() 
hashCollisions =  Array.new()

#iterate through all localDir
# if music type, index md5 hash into localMusic Hash
# if original image type, 
#   check for cover
#   if cover exists, check age against db
#   if cover doesn't exist or image newer than db, make new cover


for lDir in localDir do
  Find.find(lDir) do |f|
    if File.file?(f)
      
      #put music files:path into localMusic Hash
      if musicTypes.index(File.extname(f).downcase) != nil
        fHash = findLargeHash(f)
        if localMusic[fHash] != nil
          puts "error! hash collision!"
          hashCollisions.push(fHash)
          hashCollisions.push(localMusic[fHash])
          hashCollisions.push(f)
        end
        localMusic[fHash] = File.dirname(f)
      #original image
      elsif imageTypes.index(File.extname(f).downcase) != nil and File.basename(f, File.extname(f)) == originalName
        fHash = findSmallHash(f)
        Dir.chdir(File.dirname(f))
        
        #flag for making new cover
        coverFlag = 0
        
        #path is unique, so first row is fine
        row = db.get_first_row( " select * from AlbumFiles where path = :path " , "path" => File.dirname(f) )
        
        #cover exists
        if File.exist?( "#{coverName}#{coverType}" ) == true
          #if row doesn't exist (not in db), make new cover anyway
          if row == nil
            coverFlag = 1
          else
            #check original image hash against db, if different, make new
            if row[1] != fHash
              coverFlag = 1
            end
          end
        else
          #cover doesn't exist, just make a new one
          coverFlag = 1
        end
        
        #need to make a new cover and add hashes to db
        if coverFlag == 1
          
          q = QuickMagick::Image.read(File.basename(f)).first
          q.resize("#{coverWidth}x#{coverHeight}")
          q.save("#{coverName}#{coverType}")
          
          cover = File.new("#{coverName}#{coverType}")
          
          puts "making new cover for #{f}"
          
          #insert if not in db, update otherwise
          if row == nil
            db.execute( "insert into AlbumFiles values (:path, :oHash, :cHash)", 
                        "path" => File.dirname(f),
                        "oHash" => fHash,
                        "cHash" => findSmallHash(cover) )
          else
            db.execute( "update AlbumFiles set originalHash=:oHash, coverHash=:cHash where path=:path",
              "path" => File.dirname(f),
              "oHash" => fHash,
              "cHash" => findSmallHash(cover) )
          end
          
          
          cover.close()
        end
        
      end
      count=count+1
    end
  end
end

puts "local files indexed and covers created"

#stores music files not found
notFound = Array.new()

#now, iterate through all destDir
# if music type, check current dir for cover
#   if exists, check db for cover age, replace if old
#   if not, replace cover

for dDir in destDir do
  Find.find(dDir) do |f|
    if File.file?(f)
      
      #check music files against localMusic Hash, get path if possible
      if musicTypes.index(File.extname(f).downcase) != nil
        fHash = findLargeHash(f)
        lPath = localMusic[fHash]

        if lPath == nil
          puts "music file not found in index!"
          notFound.push(f)
          count = count + 1
          next
        end
        
        Dir.chdir(File.dirname(f))
        replaceFlag = 0
      
        #cover exists
        if File.exist?( "#{coverName}#{coverType}" ) == true  
          #check age by checking against db
          cover = File.new("#{coverName}#{coverType}")
          cHash = findSmallHash(cover)
          row = db.get_first_row( " select * from AlbumFiles where path = :path " , "path" => lPath )
          #puts row
          if row == nil
            puts "path not in db!"
            puts lPath
          end
          if row[2] != cHash
            replaceFlag = 1
          end
          cover.close()
        else
          replaceFlag = 1
        end
        
        if replaceFlag == 1
          lCoverPath = File.join(lPath, coverName + coverType)
          dCoverPath = File.join(File.dirname(f), coverName  + coverType)
          puts "new cover for #{f}"
          #puts lCoverPath
          #puts dCoverPath
          FileUtils.copy_file(lCoverPath,dCoverPath)
        end
        
        count = count+1
      end
      
    end
  end
end

if hashCollisions.size != 0
  puts "hash collisions: "
  puts hashCollisions
end

if notFound.size != 0
  puts "not found: "
  puts notFound
end

puts "finished!"
puts "count: #{count}"
puts "time: #{Time.now - time}"