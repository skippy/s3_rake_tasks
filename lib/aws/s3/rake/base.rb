module AWS
  module S3
    module Rake
      
      class Base
      
        class << self
          # initialize a S3 connection 
          def init
            begin
              file =
              @@s3_configs ||= YAML::load(ERB.new(IO.read("#{RAILS_ROOT}/config/s3.yml")).result)
            rescue 
              return Utils.msg "#{RAILS_ROOT}/config/s3.yml not found..." unless @@s3_configs
            end

            begin
              AWS::S3::Base.establish_connection!(
                :access_key_id     => @@s3_configs['aws_access_key'], 
                :secret_access_key => @@s3_configs['aws_secret_access_key'],
                :use_ssl => @@s3_configs['options']['use_ssl'] || true,
                :persistent => @@s3_configs['options']['persistent'] || true
              )
              #test to see if it exists
              AWS::S3::Base.connected?
            rescue Exception => e 
              Utils.msg "The connection to AWS::S3 failed.  Make sure '#{RAILS_ROOT}/config/s3.yml' is correctly setup."
              raise e              
            end
          end
          
          def find_or_create_bucket(name, options=bucket_options)
            bucket = Bucket.find(name, options) rescue nil
            Bucket.create(name, options) unless bucket
            bucket ||= Bucket.find(name, options)
          end
          
          def bucket_options
            options = {}
            options.merge!(:max_keys => ENV['MAX_KEYS'].to_i) if ENV['MAX_KEYS']
            options
          end
          
          def unpack_retrieved_object(file)
            cmd = ""
            if file =~ /\.sig$|\.gpg$|\.pgp$/
              unless @@s3_configs['private_signing_key_name'].blank?
                Utils.msg "Unsigning package with the servers signing key: #{@@s3_configs['private_signing_key_name']}"
                cmd += "gpg -d -r '#{@@s3_configs['private_signing_key_name']}' #{file} | "
              end
              unless @@s3_configs['public_encryption_key'].blank?
                encryptionKey = handle_encryption_key
                Utils.msg "Decrypting the package with your private key: #{encryptionKey}"
                first_cmd = cmd.blank?
                cmd += "gpg -d -r '#{encryptionKey}' "
                cmd += file if first_cmd
                cmd += " | "
              end              
            end
            if file =~ /\.tgz|\.tar.gz/
              cmd = cmd.blank? ? "tar -xzf #{file}" : "#{cmd} tar -xz"
            end
            return if cmd.blank?
            Utils.msg "cmd: #{cmd}"
            `#{cmd}`
          end
          
          def retrieve_db_info
            # read the remote database file....
            # there must be a better way to do this...
            result = File.read "#{RAILS_ROOT}/config/database.yml"
            result.strip!
            config_file = YAML::load(ERB.new(result).result)
            return [
              config_file[RAILS_ENV]['database'],
              config_file[RAILS_ENV]['username'],
              config_file[RAILS_ENV]['password'],
              config_file[RAILS_ENV]['host']
            ]
          end
              
              
          private

          def handle_encryption_key
            tmp_file = Tempfile.new('backup.pub')
            tmp_file << @@s3_configs['public_encryption_key']
            tmp_file.close
            # that will either say the key was added OR that it wasn't needed, but either way we need to parse for the uid
            # which will be wrapped in '<' and '>' like <sweetspot-backup2007@6bar8.com>
            output = `gpg --import #{tmp_file.path} 2>&1`
            output.match(/<(.+)>/)[1] 
          end     
            
        end
        
      end #class Base
      
    end #module Rake
  end
end