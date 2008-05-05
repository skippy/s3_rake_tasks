module AWS
  module S3
    module Rake
      
      class Static < Base
        class << self
          
          # influenced by Casey Muller.  thanks!
          # http://casey0.com/archive/2006/October/How_to_serve_the_rails_public_directory_out_of_S3.html
          # http://wiki.rubyonrails.org/rails/pages/HowtoServeStaticFilesFromAmazonsS3
          def upload (path, bucket, s3_options)
            upload_recursive(path, path, bucket, s3_options)
          end

          private

          def upload_recursive(orig_path, new_path, bucket , s3_options={})  
            if File.directory?(new_path)
              # go recursive
              Dir.foreach(new_path) do |file|
                if /^[^\.].*$/.match(file)
                  upload_recursive(orig_path, "#{new_path}/#{file}", bucket, s3_options)
                end
              end
              return
            end
            # it's a file, check for validity and upload it
            if /^#{orig_path}\/(.+[^~])$/.match(new_path) && File.readable?(new_path)
              key = Regexp.last_match[1]
              # need to clone the original s3_options hash because somewhere within the S3Object call, it modifies the incoming
              # options hash...big NO NO!, but easy to do ;)  The end result is that it will take the first 'content-type' and apply
              # that for all other options it will want to store.  I found this because the first item was 'text/html', so then it saved
              # everything like that, includes images and flash files.  woops!
              S3Object.store(key, open(new_path), bucket.name, s3_options.clone)
            end
          end
          
        end
      end #class Static

    end
  end
end