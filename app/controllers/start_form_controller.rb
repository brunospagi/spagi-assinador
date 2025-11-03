# frozen_string_literal: true

class StartFormController < ApplicationController
  layout 'form'

  skip_before_action :authenticate_user!
  skip_authorization_check

  around_action :with_browser_locale, only: %i[show completed]
  before_action :maybe_redirect_com, only: %i[show completed]
  before_action :load_template

  def show
    @submitter = @template.submissions.new(account_id: @template.account_id)
                          .submitters.new(uuid: (filter_undefined_submitters(@template).first ||
                                                 @template.submitters.first)['uuid'])
  end

  def update
    return redirect_to start_form_path(@template.slug) if @template.archived_at?

    # --- INÍCIO DA MODIFICAÇÃO ---
    allowed_params = submitter_params
    lookup_params = allowed_params.except(:values) # Params para encontrar o submitter
    new_values = allowed_params[:values] || {}      # Params do CPF
    # --- FIM DA MODIFICAÇÃO ---

    @submitter = find_or_initialize_submitter(@template, lookup_params) # Usar lookup_params

    if @submitter.completed_at?
      redirect_to start_form_completed_path(@template.slug, email: lookup_params[:email]) # Usar lookup_params
    else
      if filter_undefined_submitters(@template).size > 1 && @submitter.new_record?
        @error_message = I18n.t('not_found')

        return render :show
      end

      if (is_new_record = @submitter.new_record?)
        # Passar os novos valores (CPF) para serem atribuídos
        assign_submission_attributes(@submitter, @template, new_values:)
      else
        # Se o submitter já existir, apenas faz o merge dos novos valores
        @submitter.values.merge!(new_values)
      end

      Submissions::AssignDefinedSubmitters.call(@submitter.submission) if is_new_record

      if @submitter.save
        if is_new_record
          WebhookUrls.for_account_id(@submitter.account_id, 'submission.created').each do |webhook_url|
            SendSubmissionCreatedWebhookRequestJob.perform_async('submission_id' => @submitter.submission_id,
                                                                 'webhook_url_id' => webhook_url.id)
          end
        end

        redirect_to submit_form_path(@submitter.slug)
      else
        render :show
      end
    end
  end

  def completed
    @submitter = Submitter.where(submission: @template.submissions)
                          .where.not(completed_at: nil)
                          .find_by!(email: params[:email])
  end

  private

  def find_or_initialize_submitter(template, submitter_params)
    Submitter.where(submission: template.submissions.where(expire_at: Time.current..)
                                        .or(template.submissions.where(expire_at: nil)).where(archived_at: nil))
             .order(id: :desc)
             .where(declined_at: nil)
             .where(external_id: nil)
             .then { |rel| params[:resubmit].present? ? rel.where(completed_at: nil) : rel }
             .find_or_initialize_by(**submitter_params.compact_blank)
  end

  # Adicionado 'new_values: {}' aos argumentos
  def assign_submission_attributes(submitter, template, new_values: {})
    resubmit_submitter =
      (Submitter.where(submission: template.submissions).find_by(slug: params[:resubmit]) if params[:resubmit].present?)

    # --- INÍCIO DA MODIFICAÇÃO ---
    # Carregar valores padrão (se for um re-envio) ou um hash vazio
    default_values = resubmit_submitter&.preferences&.fetch('default_values', nil) || {}
    # Fazer merge dos novos valores (CPF) sobre os valores padrão
    default_values.merge!(new_values)
    # --- FIM DA MODIFICAÇÃO ---

    submitter.assign_attributes(
      uuid: (filter_undefined_submitters(template).first || @template.submitters.first)['uuid'],
      ip: request.remote_ip,
      ua: request.user_agent,
      values: default_values, # Usar os valores combinados
      preferences: resubmit_submitter&.preferences.presence || { 'send_email' => true },
      metadata: resubmit_submitter&.metadata.presence || {}
    )

    if submitter.values.present?
      resubmit_submitter.attachments.each do |attachment|
        submitter.attachments << attachment.dup if submitter.values.value?(attachment.uuid)
      end
    end

    submitter.submission ||= Submission.new(template:,
                                            account_id: template.account_id,
                                            template_submitters: template.submitters,
                                            submitters: [submitter],
                                            source: :link)

    submitter.account_id = submitter.submission.account_id

    submitter
  end

  def filter_undefined_submitters(template)
    Templates.filter_undefined_submitters(template)
  end

  def submitter_params
    # --- INÍCIO DA MODIFICAÇÃO ---
    # Permitir o hash 'values' para receber o CPF
    params.require(:submitter).permit(:email, :phone, :name, values: {}).tap do |attrs|
    # --- FIM DA MODIFICAÇÃO ---
      attrs[:email] = Submissions.normalize_email(attrs[:email])
    end
  end

  def load_template
    slug = params[:slug] || params[:start_form_slug]

    @template = Template.find_by!(slug:)
  end
end