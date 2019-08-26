<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform" 
  xmlns:w="http://java.sun.com/xml/ns/javaee">
<xsl:output method="xml" version="1.0" encoding="UTF-8" indent="yes"/>

<xsl:template match="@*|node()">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()" />
    </xsl:copy>
  </xsl:template>

  <xsl:template match="w:filter[w:filter-name='JiraFirstFilter']">
    <xsl:copy>
        <xsl:apply-templates select="@*|node()"/>
    </xsl:copy>

    <filter>
      <filter-name>ApplicationInsightsWebFilter</filter-name>
      <filter-class>com.microsoft.applicationinsights.web.internal.WebRequestTrackingFilter</filter-class>
    </filter>
  </xsl:template>

  <xsl:template match="w:filter-mapping[w:filter-name='JiraFirstFilter']">
    <xsl:copy>
        <xsl:apply-templates select="@*|node()"/>
    </xsl:copy>

    <filter-mapping>
       <filter-name>ApplicationInsightsWebFilter</filter-name>
       <url-pattern>/*</url-pattern>
    </filter-mapping>
    
  </xsl:template>

</xsl:stylesheet>