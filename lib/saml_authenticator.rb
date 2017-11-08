class SamlAuthenticator < ::Auth::OAuth2Authenticator

  def register_middleware(omniauth)
    omniauth.provider :saml,
                      :name => 'saml',
                      :issuer => Discourse.base_url,
                      :idp_sso_target_url => GlobalSetting.try(:saml_target_url),
                      :idp_cert_fingerprint => GlobalSetting.try(:saml_cert_fingerprint),
                      :idp_cert => GlobalSetting.try(:saml_cert),
                      :attribute_statements => { :nickname => ['screenName'] },
                      :assertion_consumer_service_url => Discourse.base_url + "/auth/saml/callback",
                      :custom_url => (GlobalSetting.try(:saml_request_method) == 'post') ? "/discourse_saml" : nil,
                      :certificate => GlobalSetting.try(:saml_sp_certificate),
                      :private_key => GlobalSetting.try(:saml_sp_private_key),
                      :security => {
                        authn_requests_signed: GlobalSetting.try(:saml_authn_requests_signed) ? true : false,
                        want_assertions_signed: GlobalSetting.try(:saml_want_assertions_signed) ? true : false,
                        signature_method: XMLSecurity::Document::RSA_SHA1
                      }
  end

  def after_authenticate(auth)
    result = Auth::Result.new

    if GlobalSetting.try(:saml_log_auth)
      ::PluginStore.set("saml", "saml_last_auth", auth.inspect)
      ::PluginStore.set("saml", "saml_last_auth_raw_info", auth.extra[:raw_info].inspect)
      ::PluginStore.set("saml", "saml_last_auth_extra", auth.extra.inspect)
    end

    if GlobalSetting.try(:saml_debug_auth)
      log("saml_auth_info: #{auth[:info].inspect}")
      log("saml_auth_extra: #{auth.extra.inspect}")
    end

    uid = auth[:uid]
    result.name = auth[:info].name || uid
    result.username = uid
    if auth.extra.present? && auth.extra[:raw_info].present?
      result.username = auth.extra[:raw_info].attributes['screenName'].try(:first) || uid
    end

    if GlobalSetting.try(:saml_use_uid) && auth.extra.present? && auth.extra[:raw_info].present?
      result.username = auth.extra[:raw_info].attributes['uid'].try(:first) || uid
    end

    result.email = auth[:info].email || uid

    if result.respond_to?(:skip_email_validation) && GlobalSetting.try(:saml_skip_email_validation)
      result.skip_email_validation = true
    end

    saml_user_info = ::PluginStore.get("saml", "saml_user_#{uid}")
    if saml_user_info
      result.user = User.where(id: saml_user_info[:user_id]).first
    end

    result.user ||= User.find_by_email(result.email)

    if saml_user_info.nil? && result.user
      ::PluginStore.set("saml", "saml_user_#{uid}", {user_id: result.user.id })
    end

    if GlobalSetting.try(:saml_validate_email_fields).present? && auth.extra[:raw_info].attributes['memberOf'].present?
      unless (GlobalSetting.try(:saml_validate_email_fields).split("|").map(&:downcase) & auth.extra[:raw_info].attributes['memberOf'].map(&:downcase)).empty?
        result.email_valid = true
      else
        result.email_valid = false
      end
    elsif GlobalSetting.try(:saml_default_emails_valid).present? && GlobalSetting.try(:saml_default_emails_valid) == "false"
      result.email_valid = false
    else
      result.email_valid = true
    end

    if GlobalSetting.try(:saml_clear_username) && result.user.blank?
      result.username = ''
    end

    if GlobalSetting.try(:saml_omit_username) && result.user.blank?
      result.omit_username = true
    end

    result.extra_data = { saml_user_id: uid }

    if GlobalSetting.try(:saml_sync_groups)
      groups = auth.extra[:raw_info].attributes['memberOf']

      if result.user.blank?
        result.extra_data[:saml_groups] = groups
      else
        sync_groups(result.user, groups)
      end
    end

    sync_email(result.user, Email.downcase(result.email)) if GlobalSetting.try(:saml_sync_email) && result.user.present? && result.user.email != Email.downcase(result.email)

    result
  end

  def log(info)
    Rails.logger.warn("SAML Debugging: #{info}") if GlobalSetting.try(:saml_debug_auth)
  end

  def after_create_account(user, auth)
    ::PluginStore.set("saml", "saml_user_#{auth[:extra_data][:saml_user_id]}", {user_id: user.id })

    sync_groups(user, auth[:extra_data][:saml_groups])
  end

  def sync_groups(user, saml_groups)

    return unless GlobalSetting.try(:saml_sync_groups) && GlobalSetting.try(:saml_sync_groups_list) && saml_groups.present?

    total_group_list = GlobalSetting.try(:saml_sync_groups_list).split('|')

    user_group_list = saml_groups

    groups_to_add = Group.where(name: total_group_list & user_group_list)

    groups_to_add.each do |group|
      group.add user
    end

    groups_to_remove = Group.where(name: total_group_list - user_group_list)

    groups_to_remove.each do |group|
      group.remove user
    end
  end

  def sync_email(user, email)
    return unless GlobalSetting.try(:saml_sync_email)

    existing_user = User.find_by_email(email)
    if email =~ EmailValidator.email_regex && existing_user.nil?
      user.email = email
      user.save
    end
  end

end
