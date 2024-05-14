module AWS
  VERSION = "0.1.1"

  class_property access_key_id : String = ENV["AWS_ACCESS_KEY_ID"]? || ""
  class_property secret_access_key : String = ENV["AWS_SECRET_ACCESS_KEY"]? || ""
  class_property region : String = ENV["AWS_REGION"]? || ""
  class_property use_tls : Bool = ENV["AWS_USE_TLS"] == "false" ? false : true

  class Exception < ::Exception
  end

  class InvalidCredentials < Exception
  end
end
