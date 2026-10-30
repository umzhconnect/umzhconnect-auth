package org.umzhconnect.keycloak;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.services.clientpolicy.executor.ClientPolicyExecutorProvider;
import org.keycloak.services.clientpolicy.executor.ClientPolicyExecutorProviderFactory;

import java.util.Collections;
import java.util.List;

public class ContextExecutorFactory implements ClientPolicyExecutorProviderFactory {

    public static final String PROVIDER_ID = "umzh-context-executor";

    @Override public String getId() { return PROVIDER_ID; }

    @Override
    public ClientPolicyExecutorProvider create(KeycloakSession session) {
        return new ContextExecutor();
    }

    @Override public void init(Config.Scope config) {}
    @Override public void postInit(KeycloakSessionFactory factory) {}
    @Override public void close() {}

    @Override
    public String getHelpText() {
        return "Rejects client_credentials token requests whose authorization_details are not "
             + "exactly one UMZH Connect context (" + ContextAuthorizationDetails.TYPE + ").";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return Collections.emptyList();
    }
}
